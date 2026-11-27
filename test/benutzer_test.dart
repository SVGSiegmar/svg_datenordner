import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:svg_datenordner/svg_datenordner.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late SvgBenutzerverwaltung kb;
  late SvgBenutzerverwaltung kgv;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('svg_benutzer_');
    final ordner = Datenordner(tmp.path);
    kb = SvgBenutzerverwaltung(SvgBenutzerDatei.imOrdner(ordner, app: 'Kassenbuch'), app: SvgRechte.kassenbuch)
      ..durchlaeufe = 1000;
    kgv = SvgBenutzerverwaltung(SvgBenutzerDatei.imOrdner(ordner, app: 'Kleingartenverwaltung'),
        app: SvgRechte.kleingartenverwaltung)
      ..durchlaeufe = 1000;
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('SvgPasswort', () {
    test('PBKDF2 sichern und prüfen', () {
      final h = SvgPasswort.sichernSync('geheim123', anzahl: 1000);
      expect(h, startsWith('pbkdf2-sha256\$1000\$'));
      expect(SvgPasswort.pruefenSync('geheim123', h), isTrue);
      expect(SvgPasswort.pruefenSync('geheim124', h), isFalse);
      expect(SvgPasswort.veraltet(h), isFalse);
    });

    test('gleiches Passwort ergibt verschiedene Prüfwerte (Salz)', () {
      expect(SvgPasswort.sichernSync('abcdefgh', anzahl: 10), isNot(SvgPasswort.sichernSync('abcdefgh', anzahl: 10)));
    });

    test('alter Eintrag (SHA-256 ohne Salz) wird erkannt', () {
      final alt = sha256.convert(utf8.encode('altesPasswort')).toString();
      expect(SvgPasswort.veraltet(alt), isTrue);
      expect(SvgPasswort.pruefenSync('altesPasswort', alt), isTrue);
      expect(SvgPasswort.pruefenSync('falsch', alt), isFalse);
      expect(SvgPasswort.pruefenSync('x', ''), isFalse);
    });

    test('Regeln', () {
      expect(SvgPasswort.regelnPruefen('kurz'), isNotNull);
      expect(SvgPasswort.regelnPruefen('langgenug', 'anders123'), isNotNull);
      expect(SvgPasswort.regelnPruefen('langgenug', 'langgenug'), isNull);
    });
  });

  group('SvgBenutzerverwaltung', () {
    test('leer ohne Datei, Anmeldung aus', () async {
      final s = await kb.lesen();
      expect(s.benutzer, isEmpty);
      expect(s.anmeldungAktiv, isFalse);
      expect(s.anmeldungMoeglich, isFalse);
    });

    test('anlegen, anmelden mit Name und E-Mail, Datei im Ordner daten/', () async {
      await kb.anlegen(name: 'Kassenwart', email: 'kasse@verein.de', passwort: 'geheim123', admin: true);
      expect(await File('${tmp.path}/daten/benutzer.json').exists(), isTrue);
      expect((await kb.anmelden('kassenwart', 'geheim123')).erfolgreich, isTrue);
      expect((await kb.anmelden('KASSE@verein.de', 'geheim123')).erfolgreich, isTrue);
      expect((await kb.anmelden('kassenwart', 'falsch123')).erfolgreich, isFalse);
      // Passwort steht nie im Klartext in der Datei
      final text = await File('${tmp.path}/daten/benutzer.json').readAsString();
      expect(text.contains('geheim123'), isFalse);
      // Schreibsperre ist wieder frei
      expect(await File('${tmp.path}/locks/schreibsperre.json').exists(), isFalse);
    });

    test('doppelter Name oder doppelte E-Mail wird abgelehnt', () async {
      await kb.anlegen(name: 'Anna', email: 'a@v.de', passwort: 'geheim123', admin: true);
      await expectLater(kb.anlegen(name: 'anna', passwort: 'geheim123'), throwsA(isA<SvgBenutzerFehler>()));
      await expectLater(kb.anlegen(name: 'Bert', email: 'A@v.de'), throwsA(isA<SvgBenutzerFehler>()));
      await expectLater(kb.anlegen(name: 'Carl', email: 'keine-mail'), throwsA(isA<SvgBenutzerFehler>()));
    });

    test('letzter Administrator: nicht löschen, sperren, herabstufen', () async {
      final a = await kb.anlegen(name: 'Admin', email: 'admin@v.de', passwort: 'geheim123', admin: true);
      await expectLater(kb.loeschen(a.id), throwsA(isA<SvgBenutzerFehler>()));
      await expectLater(kb.benutzerAendern(a.id, (b) => b.aktiv = false), throwsA(isA<SvgBenutzerFehler>()));
      await expectLater(kb.benutzerAendern(a.id, (b) => b.rolle = SvgBenutzer.rolleBenutzer), throwsA(isA<SvgBenutzerFehler>()));
      expect((await kb.lesen()).aktiveAdmins.length, 1);
      // mit zweitem Administrator geht es
      await kb.anlegen(name: 'Admin2', passwort: 'geheim123', admin: true);
      await kb.loeschen(a.id);
      expect((await kb.lesen()).benutzer.single.name, 'Admin2');
    });

    test('Anmeldung erst mit Administrator mit E-Mail', () async {
      await kb.anlegen(name: 'Admin', passwort: 'geheim123', admin: true);
      await expectLater(kb.anmeldungSchalten(true), throwsA(isA<SvgBenutzerFehler>()));
      final a = (await kb.lesen()).benutzer.single;
      await kb.benutzerAendern(a.id, (b) => b.email = 'admin@v.de');
      await kb.anmeldungSchalten(true);
      expect(await kb.anmeldungAktiv(), isTrue);
      // E-Mail des einzigen Administrators entfernen geht dann nicht mehr
      await expectLater(kb.benutzerAendern(a.id, (b) => b.email = ''), throwsA(isA<SvgBenutzerFehler>()));
    });

    test('Rechte je App: eine Person, ein Konto für beide Apps', () async {
      await kb.anlegen(name: 'Admin', email: 'admin@v.de', passwort: 'geheim123', admin: true);
      final u = await kb.anlegen(name: 'Bea', passwort: 'geheim123', rechte: ['buchungen_ansehen']);
      await kgv.rechteSetzen(u.id, ['mitglieder.sehen']);
      final b = (await kb.lesen()).nachId(u.id)!;
      expect(b.rechte[SvgRechte.kassenbuch], ['buchungen_ansehen']);
      expect(b.rechte[SvgRechte.kleingartenverwaltung], ['mitglieder.sehen']);
      expect(b.darf(SvgRechte.kassenbuch, 'buchungen_ansehen'), isTrue);
      expect(b.darf(SvgRechte.kassenbuch, 'jahresabschluss'), isFalse);
      expect(kb.darf(b, 'jahresabschluss', anmeldungAktiv: false), isTrue);
      expect(kb.darf(b, 'jahresabschluss', anmeldungAktiv: true), isFalse);
      expect(kb.darf(null, 'buchungen_ansehen', anmeldungAktiv: true), isFalse);
      // die Kleingartenverwaltung meldet sich mit demselben Konto an
      expect((await kgv.anmelden('bea', 'geheim123')).erfolgreich, isTrue);
      // gesperrt: keine Anmeldung, keine Rechte
      await kb.benutzerAendern(u.id, (x) => x.aktiv = false);
      final r = await kgv.anmelden('bea', 'geheim123');
      expect(r.erfolgreich, isFalse);
      expect(r.meldung, contains('gesperrt'));
    });

    test('Administrator setzt Passwort zurück', () async {
      final a = await kb.anlegen(name: 'Admin', email: 'admin@v.de', passwort: 'geheim123', admin: true);
      await kb.passwortSetzen(a.id, 'neuesPasswort1');
      expect((await kb.anmelden('admin', 'geheim123')).erfolgreich, isFalse);
      expect((await kb.anmelden('admin', 'neuesPasswort1')).erfolgreich, isTrue);
      await expectLater(kb.passwortSetzen(a.id, 'kurz'), throwsA(isA<SvgBenutzerFehler>()));
    });

    test('Passwort vergessen: Code per E-Mail', () async {
      await kb.anlegen(name: 'Admin', email: 'admin@v.de', passwort: 'geheim123', admin: true);
      expect(await kb.codeErzeugen('unbekannt'), isNull);
      final c = await kb.codeErzeugen('admin@v.de');
      expect(c, isNotNull);
      expect(c!.code.length, 6);
      expect(c.benutzer.email, 'admin@v.de');
      // Code steht nicht im Klartext in der Datei
      final text = await File('${tmp.path}/daten/benutzer.json').readAsString();
      expect(text.contains('"${c.code}"'), isFalse);
      await expectLater(kb.mitCodeZuruecksetzen('admin', '000000', 'neuesPasswort1'), throwsA(isA<SvgBenutzerFehler>()));
      await kb.mitCodeZuruecksetzen('admin', c.code, 'neuesPasswort1');
      expect((await kb.anmelden('admin', 'neuesPasswort1')).erfolgreich, isTrue);
      // Code ist danach verbraucht
      await expectLater(kb.mitCodeZuruecksetzen('admin', c.code, 'nochEinPasswort'), throwsA(isA<SvgBenutzerFehler>()));
    });

    test('Code: nach fünf falschen Versuchen gesperrt, abgelaufen ungültig', () async {
      await kb.anlegen(name: 'Admin', email: 'admin@v.de', passwort: 'geheim123', admin: true);
      final c = await kb.codeErzeugen('admin');
      for (var i = 0; i < SvgBenutzerverwaltung.codeVersuche; i++) {
        await expectLater(kb.mitCodeZuruecksetzen('admin', 'x$i', 'neuesPasswort1'), throwsA(isA<SvgBenutzerFehler>()));
      }
      await expectLater(kb.mitCodeZuruecksetzen('admin', c!.code, 'neuesPasswort1'), throwsA(isA<SvgBenutzerFehler>()));
      kb.codeGueltig = const Duration(milliseconds: -1);
      final c2 = await kb.codeErzeugen('admin');
      await expectLater(kb.mitCodeZuruecksetzen('admin', c2!.code, 'neuesPasswort1'), throwsA(isA<SvgBenutzerFehler>()));
    });

    test('alter Prüfwert wird bei der Anmeldung auf PBKDF2 umgestellt', () async {
      await kgv.ausKleingartenverwaltungUebernehmen([
        {
          'id': '17',
          'name': 'admin',
          'passwortHash': sha256.convert(utf8.encode('altesPasswort')).toString(),
          'recoveryHash': 'x',
          'istAdmin': true,
          'freigegeben': true,
          'rechte': {
            'mitglieder': {'sichtbar': true, 'schreiben': false},
          },
        },
        {'id': '18', 'name': 'gast', 'passwortHash': '', 'istAdmin': false, 'freigegeben': false},
      ]);
      var s = await kgv.lesen();
      expect(s.benutzer.length, 2);
      expect(s.suchen('admin')!.istAdmin, isTrue);
      expect(s.suchen('admin')!.rechte[SvgRechte.kleingartenverwaltung], ['mitglieder.sehen']);
      expect(s.suchen('gast')!.aktiv, isFalse);
      expect(s.suchen('admin')!.weitere.containsKey('recoveryHash'), isFalse);
      expect((await kgv.anmelden('admin', 'altesPasswort')).erfolgreich, isTrue);
      s = await kgv.lesen();
      expect(SvgPasswort.veraltet(s.suchen('admin')!.passwort), isFalse);
      // zweite Übernahme ändert nichts mehr
      expect(await kgv.ausKleingartenverwaltungUebernehmen([{'name': 'neu', 'istAdmin': true}]), 0);
    });

    test('unbekannte Felder bleiben erhalten', () async {
      final f = File('${tmp.path}/daten/benutzer.json');
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({
        'format': 'svg-benutzer',
        'version': 1,
        'zukunft': 42,
        'benutzer': [
          {'id': 'a1', 'name': 'Admin', 'rolle': 'admin', 'aktiv': true, 'passwort': '', 'neuesFeld': 'bleibt'},
        ],
      }));
      await kb.anlegen(name: 'Zweiter', passwort: 'geheim123');
      final roh = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      expect(roh['zukunft'], 42);
      expect((roh['benutzer'] as List).first['neuesFeld'], 'bleibt');
    });

    test('lokal ohne Datenordner: Datei im Datenbereich der App', () async {
      final lokal = SvgBenutzerverwaltung(SvgBenutzerDatei.lokal(tmp, app: 'Kassenbuch'), app: SvgRechte.kassenbuch)
        ..durchlaeufe = 1000;
      await lokal.anlegen(name: 'Einzelplatz', passwort: 'geheim123', admin: true);
      expect(await File('${tmp.path}/benutzer.json').exists(), isTrue);
    });

    test('Rechte-Kataloge', () {
      expect(SvgRechte.fuer(SvgRechte.kassenbuch), contains('zahlungen_zurueckmelden'));
      expect(SvgRechte.fuer(SvgRechte.kleingartenverwaltung), contains('mitglieder.aendern'));
      expect(SvgRechte.fuer('unbekannt'), isEmpty);
    });
  });
}
