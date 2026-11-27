import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:svg_datenordner/svg_datenordner.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Datenordner ordner;
  late Benutzerverwaltung v;
  var jetzt = DateTime(2026, 11, 28, 10);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('svg-benutzer-');
    ordner = Datenordner(tmp.path);
    jetzt = DateTime(2026, 11, 28, 10);
    v = Benutzerverwaltung(ordner, app: 'Kassenbuch', benutzer: 'Test', uhr: () => jetzt);
  });
  tearDown(() => tmp.delete(recursive: true));

  test('ohne Datei: leere Liste, Anmeldung aus', () async {
    final l = await v.lesen();
    expect(l.benutzer, isEmpty);
    expect(l.anmeldungAktiv, isFalse);
    expect(ordner.benutzerDatei.path, endsWith('benutzer.json'));
  });

  test('anlegen: erstes Konto Admin, Passwort nur als Prüfwert, eindeutig', () async {
    final a = await v.anlegen(benutzername: 'Kasse', email: 'kasse@example.org', passwort: 'geheim123');
    expect(a.admin, isTrue);
    final b = await v.anlegen(benutzername: 'Pruefer', passwort: 'geheim123',
        rechte: {Benutzerverwaltung.appKassenbuch: ['buchungen_ansehen']});
    expect(b.admin, isFalse);
    final text = await ordner.benutzerDatei.readAsString();
    expect(text, isNot(contains('geheim123')));
    expect(text, contains('pbkdf2-sha256\$'));
    await expectLater(v.anlegen(benutzername: 'KASSE@example.org', passwort: 'geheim123'),
        throwsA(isA<BenutzerFehler>()));
    await expectLater(v.anlegen(benutzername: 'x', passwort: 'kurz'),
        throwsA(isA<BenutzerFehler>()));
    expect(b.darf('kassenbuch', 'buchungen_ansehen'), isTrue);
    expect(b.darf('kassenbuch', 'buchungen_erfassen'), isFalse);
    expect(b.darf('kleingartenverwaltung', 'buchungen_ansehen'), isFalse);
    expect(a.darf('kleingartenverwaltung', 'irgendwas'), isTrue);
  });

  test('anmelden mit Name oder E-Mail, deaktiviert nicht', () async {
    final a = await v.anlegen(benutzername: 'Kasse', email: 'kasse@example.org', passwort: 'geheim123');
    expect((await v.anmelden('kasse', 'geheim123'))?.id, a.id);
    expect((await v.anmelden('KASSE@example.org', 'geheim123'))?.id, a.id);
    expect(await v.anmelden('kasse', 'falsch!!'), isNull);
    final b = await v.anlegen(benutzername: 'zwei', passwort: 'geheim123');
    await v.bearbeiten(b.id, aktiv: false);
    expect(await v.anmelden('zwei', 'geheim123'), isNull);
    expect((await v.lesen()).nachId(a.id)!.letzteAnmeldung, isNotEmpty);
  });

  test('letzter Administrator bleibt, Anmeldung nur mit Admin-E-Mail', () async {
    final a = await v.anlegen(benutzername: 'Kasse', passwort: 'geheim123');
    await expectLater(v.bearbeiten(a.id, admin: false), throwsA(isA<BenutzerFehler>()));
    await expectLater(v.bearbeiten(a.id, aktiv: false), throwsA(isA<BenutzerFehler>()));
    await expectLater(v.loeschen(a.id), throwsA(isA<BenutzerFehler>()));
    await expectLater(v.anmeldungSchalten(true), throwsA(isA<BenutzerFehler>()));
    await v.bearbeiten(a.id, email: 'kasse@example.org');
    await v.anmeldungSchalten(true);
    expect((await v.lesen()).anmeldungAktiv, isTrue);
    // E-Mail des einzigen Admins entfernen geht nicht, solange die Anmeldung an ist
    await expectLater(v.bearbeiten(a.id, email: ''), throwsA(isA<BenutzerFehler>()));
    // zweiter Admin: dann darf der erste gelöscht werden
    final b = await v.anlegen(benutzername: 'Vorsitz', email: 'v@example.org', passwort: 'geheim123', admin: true);
    await v.loeschen(a.id);
    expect((await v.lesen()).benutzer.single.id, b.id);
  });

  test('Rechte je App: andere App bleibt unberührt, unbekannte Felder bleiben', () async {
    final a = await v.anlegen(benutzername: 'Kasse', passwort: 'geheim123');
    final b = await v.anlegen(benutzername: 'B', passwort: 'geheim123', rechte: {
      'kassenbuch': ['buchungen_ansehen'],
      'kleingartenverwaltung': ['mitglieder_ansehen'],
    });
    // eine andere App schreibt ein Feld, das diese Version nicht kennt
    final roh = jsonDecode(await ordner.benutzerDatei.readAsString()) as Map<String, dynamic>;
    roh['zusatz'] = 1;
    (roh['benutzer'] as List)[1]['telefon'] = '0345';
    await ordner.benutzerDatei.writeAsString(jsonEncode(roh));
    await v.bearbeiten(b.id, rechte: {'kassenbuch': ['buchungen_erfassen']});
    final l = await v.lesen();
    expect(l.nachId(b.id)!.rechteFuer('kassenbuch'), ['buchungen_erfassen']);
    expect(l.nachId(b.id)!.rechteFuer('kleingartenverwaltung'), ['mitglieder_ansehen']);
    expect(l.nachId(b.id)!.weitere['telefon'], '0345');
    expect(l.weitere['zusatz'], 1);
    expect(l.nachId(a.id)!.admin, isTrue);
  });

  test('alter Prüfwert (SHA-256 ohne Salz) wird bei der Anmeldung umgestellt', () async {
    final a = await v.anlegen(benutzername: 'Kasse', passwort: 'geheim123');
    final alt = sha256.convert(utf8.encode('geheim123')).toString();
    await v.aendern((l) => l.nachId(a.id)!.passwort = alt);
    expect(Benutzerverwaltung.passwortVeraltet(alt), isTrue);
    expect((await v.anmelden('Kasse', 'geheim123'))?.id, a.id);
    final neu = (await v.lesen()).nachId(a.id)!.passwort;
    expect(neu, startsWith('pbkdf2-sha256\$'));
    expect(await Benutzerverwaltung.passwortPruefen('geheim123', neu), isTrue);
  });

  test('Passwort vergessen: Code per E-Mail, einlösen, Versuche begrenzt', () async {
    final a = await v.anlegen(benutzername: 'Kasse', email: 'kasse@example.org', passwort: 'geheim123');
    String? gesendet;
    String? an;
    Future<void> versand(Postausgang p, String pw, String empf, String betreff, String text) async {
      an = empf;
      gesendet = RegExp(r'Code: (\d{6})').firstMatch(text)!.group(1);
      expect(pw, 'smtp-geheim');
    }

    await expectLater(v.codeSenden('kasse', smtpPasswort: 'smtp-geheim', versand: versand),
        throwsA(isA<BenutzerFehler>())); // Postausgang fehlt
    await v.postausgangSetzen(Postausgang(server: 'smtp.example.org', absenderAdresse: 'verein@example.org'));
    await v.codeSenden('kasse@example.org', smtpPasswort: 'smtp-geheim', versand: versand);
    expect(an, 'kasse@example.org');
    expect(await ordner.benutzerDatei.readAsString(), isNot(contains(gesendet!)));
    await expectLater(v.codeEinloesen('kasse', '000000' == gesendet ? '111111' : '000000', 'neuesPass1'),
        throwsA(isA<BenutzerFehler>()));
    await v.codeEinloesen('kasse', gesendet!, 'neuesPass1');
    expect((await v.anmelden('kasse', 'neuesPass1'))?.id, a.id);
    // Code gilt nur einmal
    await expectLater(v.codeEinloesen('kasse', gesendet!, 'nochmal12'), throwsA(isA<BenutzerFehler>()));
    // abgelaufen
    await v.codeSenden('kasse', smtpPasswort: 'smtp-geheim', versand: versand);
    jetzt = jetzt.add(const Duration(minutes: 16));
    await expectLater(v.codeEinloesen('kasse', gesendet!, 'nochmal12'), throwsA(isA<BenutzerFehler>()));
    // ohne E-Mail kein Code
    await v.anlegen(benutzername: 'ohne', passwort: 'geheim123');
    await expectLater(v.codeErzeugen('ohne'), throwsA(isA<BenutzerFehler>()));
  });

  test('nach 5 falschen Versuchen ist der Code ungültig', () async {
    await v.anlegen(benutzername: 'Kasse', email: 'kasse@example.org', passwort: 'geheim123');
    final e = await v.codeErzeugen('kasse');
    final falsch = e.code == '999999' ? '999998' : '999999';
    for (var i = 0; i < 5; i++) {
      await expectLater(v.codeEinloesen('kasse', falsch, 'neuesPass1'), throwsA(isA<BenutzerFehler>()));
    }
    await expectLater(v.codeEinloesen('kasse', e.code, 'neuesPass1'), throwsA(isA<BenutzerFehler>()));
  });

  test('Schreibsperre wird beim Ändern genutzt und freigegeben', () async {
    await v.anlegen(benutzername: 'Kasse', passwort: 'geheim123');
    expect(ordner.schreibsperreDatei.existsSync(), isFalse);
  });
}
