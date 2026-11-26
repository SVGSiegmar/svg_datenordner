import 'dart:convert';
import 'dart:io';

import 'package:svg_datenordner/svg_datenordner.dart';
import 'package:test/test.dart';

/// Kleiner Datenstand im Format der Kleingartenverwaltung – einmal durch
/// JSON geschickt, damit die Typen genau wie beim Lesen der Datei sind.
Map<String, dynamic> beispielDaten() =>
    jsonDecode(jsonEncode(_beispielRoh)) as Map<String, dynamic>;

const Map<String, dynamic> _beispielRoh = {
      'backupTyp': 'kleingarten_vollbackup',
      'stammdaten': {
        'vereinsname': 'KGV Musteranlage e.V.',
        'anschrift': 'Musterweg 1, 06112 Halle (Saale)',
        'name1': 'Max Mustermann',
        'pachtPreisProQm': 0.14,
        'unbekanntesFeld': 'bleibt erhalten',
      },
      'auth': [
        {'name': 'admin'}
      ],
      'mitglieder': [
        {
          'id': 1,
          'vorname': 'Sven',
          'name': 'Otto',
          'garten': '12a',
          'istPaechter': true,
          'eintrittsdatum': '14.02.2020',
          'austrittsdatum': '',
        },
      ],
      'nextId': 2,
      'gaerten': [
        {'parzelle': '10', 'pachtflaeche': 400.0, 'leerstand': true},
        {'parzelle': '12A', 'pachtflaeche': 390.0, 'leerstand': false},
        {'parzelle': '2', 'pachtflaeche': 350.0, 'leerstand': true},
      ],
    };

void main() {
  late Directory tmp;
  late Datenordner ordner;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('svg_datenordner_test');
    ordner = Datenordner(tmp.path);
    await ordner.grundordnerAnlegen();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('Datenordner', () {
    test('legt die Grundordner an und baut Pfade', () async {
      expect(await Directory(ordner.pfad(['daten'])).exists(), isTrue);
      expect(await Directory(ordner.pfad(['locks'])).exists(), isTrue);
      expect(await ordner.austauschOrdner.exists(), isTrue);
      expect(ordner.verwaltungForderungenDatei.path,
          endsWith('verwaltung_forderungen.json'));
      expect(ordner.kassenbuchZahlungenDatei.path,
          endsWith('kassenbuch_zahlungen.json'));
      expect(ordner.gartenvergabeDatei.path, endsWith('gartenvergabe.json'));
      expect(ordner.datenDatei.path, endsWith('app_daten.json'));
      final s = Platform.pathSeparator;
      expect(
        ordner.dokumentOrdner('Begehung', '12A', datum: DateTime(2026, 11, 17)).path,
        endsWith('dokumente${s}Begehung${s}Parzelle 12A${s}2026-11-17'),
      );
      expect(
        ordner.dokumentOrdner('Pachtvertrag', '').path,
        endsWith('dokumente${s}Pachtvertrag${s}Ohne Parzelle'),
      );
    });

    test('freieDatei überschreibt nie', () async {
      final o = ordner.dokumentOrdner('Begehung', '7');
      final erste = await Datenordner.freieDatei(o, 'Begehung_7.pdf');
      await erste.writeAsString('x');
      final zweite = await Datenordner.freieDatei(o, 'Begehung_7.pdf');
      expect(zweite.path, endsWith('Begehung_7 (2).pdf'));
    });

    test('Einstellung übersteht toJson/fromJson', () {
      const e = DatenordnerEinstellung(
        speicherart: Speicherart.ordner,
        pfad: r'\\nas\verein',
      );
      final zurueck = DatenordnerEinstellung.fromJson(e.toJson());
      expect(zurueck.speicherart, Speicherart.ordner);
      expect(zurueck.pfad, r'\\nas\verein');
      expect(zurueck.istGemeinsam, isTrue);
      expect(DatenordnerEinstellung.nurLokal.istGemeinsam, isFalse);
    });
  });

  group('Schreibsperre', () {
    test('nur eine App bekommt die Sperre', () async {
      final a = Schreibsperre(ordner.schreibsperreDatei, app: 'A');
      final b = Schreibsperre(ordner.schreibsperreDatei, app: 'B');
      expect(await a.versuchen(), isTrue);
      expect(await b.versuchen(), isFalse);
      await a.freigeben();
      expect(await b.versuchen(), isTrue);
      await b.freigeben();
      expect(await ordner.schreibsperreDatei.exists(), isFalse);
    });

    test('verwaiste Sperre wird übernommen', () async {
      final alt = Schreibsperre(
        ordner.schreibsperreDatei,
        app: 'Abgestürzt',
        uhr: () => DateTime.now().subtract(const Duration(minutes: 10)),
      );
      expect(await alt.versuchen(), isTrue);
      final neu = Schreibsperre(ordner.schreibsperreDatei, app: 'Neu');
      expect(await neu.versuchen(), isTrue);
      expect((await neu.inhaber())!['app'], 'Neu');
      // Die alte App darf die fremde Sperre nicht mehr löschen.
      await alt.freigeben();
      expect(await ordner.schreibsperreDatei.exists(), isTrue);
      await neu.freigeben();
    });

    test('erwerben gibt nach der Wartezeit auf', () async {
      final a = Schreibsperre(ordner.schreibsperreDatei, app: 'Kleingartenverwaltung');
      await a.versuchen();
      final b = Schreibsperre(ordner.schreibsperreDatei, app: 'Gartenvergabe');
      await expectLater(
        b.erwerben(
          warteZeit: const Duration(milliseconds: 300),
          intervall: const Duration(milliseconds: 50),
        ),
        throwsA(isA<SchreibsperreBelegt>()),
      );
      await a.freigeben();
    });
  });

  group('GemeinsameDaten', () {
    test('ändert nur das Gewünschte, Unbekanntes bleibt', () async {
      await ordner.datenDatei.writeAsString(jsonEncode(beispielDaten()));
      final gd = GemeinsameDaten(ordner, app: 'Test');
      final vorher = await gd.lesen();

      final nachher = await gd.aendern((d) {
        KgvDaten(d).neuesMitglied({'vorname': 'Anna', 'name': 'Neu'});
      });

      expect(await gd.wurdeGeaendert(vorher!.pruefsumme), isTrue);
      expect(await gd.wurdeGeaendert(nachher.pruefsumme), isFalse);
      final gelesen = (await gd.lesen())!.daten;
      expect(gelesen['stammdaten']['unbekanntesFeld'], 'bleibt erhalten');
      expect(gelesen['auth'], isNotEmpty);
      expect((gelesen['mitglieder'] as List).length, 2);
      expect(await ordner.schreibsperreDatei.exists(), isFalse);
    });

    test('zwei Apps nacheinander – keine Änderung geht verloren', () async {
      await ordner.datenDatei.writeAsString(jsonEncode(beispielDaten()));
      final vergabe = GemeinsameDaten(ordner, app: 'Gartenvergabe');
      final verwaltung = GemeinsameDaten(ordner, app: 'Kleingartenverwaltung');

      await Future.wait([
        vergabe.aendern((d) => KgvDaten(d).neuesMitglied({'name': 'Vergabe'})),
        verwaltung.aendern((d) => KgvDaten(d).neuesMitglied({'name': 'Verwaltung'})),
      ]);

      final namen = KgvDaten((await vergabe.lesen())!.daten)
          .mitglieder
          .map((m) => m['name'])
          .toSet();
      expect(namen, containsAll(['Otto', 'Vergabe', 'Verwaltung']));
    });

    test('leere Datei wird nicht überschrieben', () async {
      await ordner.datenDatei.writeAsString('   ');
      final gd = GemeinsameDaten(ordner, app: 'Test');
      await expectLater(gd.aendern((d) {}), throwsA(isA<FormatException>()));
      expect((await ordner.datenDatei.readAsString()).trim(), isEmpty);
    });

    test('fehlende Datei nur mit neuAnlegenErlaubt', () async {
      final gd = GemeinsameDaten(ordner, app: 'Test');
      await expectLater(gd.aendern((d) {}), throwsA(isA<StateError>()));
      await gd.aendern((d) => d['nextId'] = 1, neuAnlegenErlaubt: true);
      expect((await gd.lesen())!.daten['nextId'], 1);
    });
  });

  group('Kassenbuch-Datei (0.2.0)', () {
    test('schreibt daten/kassenbuch.json, app_daten.json bleibt unberührt',
        () async {
      await ordner.datenDatei.writeAsString(jsonEncode(beispielDaten()));
      final vorher = await ordner.datenDatei.readAsString();
      final kb = GemeinsameDaten(ordner,
          app: 'Kassenbuch', datei: ordner.kassenbuchDatei);

      await kb.aendern((d) => d['buchungen'] = [1, 2],
          neuAnlegenErlaubt: true);

      expect(ordner.kassenbuchDatei.path, endsWith('kassenbuch.json'));
      expect((await kb.lesen())!.daten['buchungen'], [1, 2]);
      expect(await ordner.datenDatei.readAsString(), vorher);
      expect(await ordner.schreibsperreDatei.exists(), isFalse);
    });

    test('erwartetePruefsumme: schreibt nur auf bekanntem Stand', () async {
      final a = GemeinsameDaten(ordner,
          app: 'Kassenbuch', datei: ordner.kassenbuchDatei);
      final b = GemeinsameDaten(ordner,
          app: 'Kassenbuch', datei: ordner.kassenbuchDatei);

      // Datei fehlt noch: erwartet '' -> erlaubt
      final stand1 = await a.aendern((d) => d['wert'] = 1,
          neuAnlegenErlaubt: true, erwartetePruefsumme: '');
      // b speichert dazwischen
      await b.aendern((d) => d['wert'] = 2);

      // a hat einen veralteten Stand -> nichts schreiben
      await expectLater(
        a.aendern((d) => d['wert'] = 3,
            erwartetePruefsumme: stand1.pruefsumme),
        throwsA(isA<DatenWurdenGeaendert>()),
      );
      expect((await a.lesen())!.daten['wert'], 2);
      expect(await ordner.schreibsperreDatei.exists(), isFalse);

      // mit aktuellem Stand klappt es
      final aktuell = (await a.lesen())!.pruefsumme;
      await a.aendern((d) => d['wert'] = 4, erwartetePruefsumme: aktuell);
      expect((await a.lesen())!.daten['wert'], 4);
    });
  });

  group('KgvDaten', () {
    test('Vereinsdaten', () {
      final k = KgvDaten(beispielDaten());
      expect(k.vereinsname, 'KGV Musteranlage e.V.');
      expect(k.vereinsort, 'Halle (Saale)');
      expect(k.vorsitz, 'Max Mustermann');
      expect(k.pachtPreisProQm, 0.14);
    });

    test('Parzellen: Schreibweise und Sortierung', () {
      final k = KgvDaten(beispielDaten());
      expect(KgvDaten.gartennummer(' 12  a '), '12 A');
      expect(k.parzelle('12a')!['pachtflaeche'], 390.0);
      expect(k.parzellennummern(), ['2', '10', '12A']);
      expect(k.parzellennummern(nurLeerstand: true), ['2', '10']);
    });

    test('neues Mitglied bekommt die nächste ID und alle Felder', () {
      final d = beispielDaten();
      final k = KgvDaten(d);
      final m = k.neuesMitglied({'id': 99, 'vorname': 'Anna', 'garten': '10'});
      expect(m['id'], 2);
      expect(d['nextId'], 3);
      expect(m['istPaechter'], isTrue);
      expect(m['mitgliedsnummer'], '');
      expect(k.mitgliedMitId(2), same(m));
    });

    test('Pächterwechsel: Vorpächter bekommt Austritt am Vortag', () {
      final k = KgvDaten(beispielDaten());
      final neu = k.neuesMitglied({
        'name': 'Neu',
        'garten': '12A',
        'eintrittsdatum': '01.12.2026',
      });
      final geaendert = k.bisherigePaechterAustragen(
        '12a',
        DateTime(2026, 12, 1),
        ausser: {neu['id'] as int},
      );
      expect(geaendert.single['name'], 'Otto');
      expect(geaendert.single['austrittsdatum'], '30.11.2026');
      expect(
        k.paechterVon('12A', stichtag: DateTime(2026, 12, 1)).single['name'],
        'Neu',
      );
    });

    test('Datum hin und zurück', () {
      expect(KgvDaten.datumKgv(DateTime(2026, 3, 5)), '05.03.2026');
      expect(KgvDaten.datumAusKgv('5.3.2026'), DateTime(2026, 3, 5));
      expect(KgvDaten.datumAusKgv('2026-03-05T10:00:00'), DateTime(2026, 3, 5));
      expect(KgvDaten.datumAusKgv(''), isNull);
    });
  });

  group('OrdnerUmzug', () {
    late Directory neuTmp;
    late Datenordner neu;

    setUp(() async {
      neuTmp = await Directory.systemTemp.createTemp('svg_umzug_ziel');
      neu = Datenordner(neuTmp.path);
    });

    tearDown(() async {
      if (await neuTmp.exists()) await neuTmp.delete(recursive: true);
    });

    Future<void> schreibe(Datenordner o, String rel, String text) async {
      final f = File(o.pfad(rel.split('/')));
      await f.parent.create(recursive: true);
      await f.writeAsString(text);
    }

    test('zählt den Bestand und nimmt alles mit, Sperren nicht', () async {
      await schreibe(ordner, 'daten/app_daten.json', '{"a":1}');
      await schreibe(ordner, 'daten/gartenvergabe.json', '{}');
      await schreibe(ordner, 'rechnungen/Parzelle 1/R1.pdf', 'pdf');
      await schreibe(ordner, 'dokumente/Begehung/Parzelle 1/B.pdf', 'pdf');
      await schreibe(ordner, 'logos/logo.png', 'png');
      await schreibe(ordner, 'locks/schreibsperre.json', '{}');
      await schreibe(ordner, 'kgv_kassenbuch.lock', '{}');
      await schreibe(ordner, '.DS_Store', 'x');

      final umzug = OrdnerUmzug(ordner, neu);
      final bestand = await umzug.pruefen();
      expect(bestand.datendateien, 2);
      expect(bestand.rechnungen, 1);
      expect(bestand.dokumente, 1);
      expect(bestand.sonstige, 1);
      expect(bestand.schonImZiel, isEmpty);
      expect(bestand.beschreibung,
          '2 Datendateien, 1 Rechnung, 1 Dokument und 1 weitere Datei');

      final ergebnis = await umzug.ausfuehren();
      expect(ergebnis.fehlerfrei, isTrue);
      expect(ergebnis.kopiert.length, 5);
      expect(await File(neu.pfad(['rechnungen', 'Parzelle 1', 'R1.pdf'])).readAsString(), 'pdf');
      expect(await File(neu.pfad(['locks', 'schreibsperre.json'])).exists(), isFalse);
      expect(await File(neu.pfad(['kgv_kassenbuch.lock'])).exists(), isFalse);
      expect(await neu.austauschOrdner.exists(), isTrue);
      // Quelle bleibt unverändert
      expect(await File(ordner.pfad(['daten', 'app_daten.json'])).exists(), isTrue);
    });

    test('überschreibt im Ziel nie eine vorhandene Datei', () async {
      await schreibe(ordner, 'daten/app_daten.json', 'alt');
      await schreibe(ordner, 'daten/neu.json', 'neu');
      await schreibe(neu, 'daten/app_daten.json', 'schon da');
      await schreibe(neu, 'daten/kassenbuch.json', 'kasse');

      final umzug = OrdnerUmzug(ordner, neu);
      final bestand = await umzug.pruefen();
      expect(bestand.schonImZiel, ['daten/app_daten.json']);

      final ergebnis = await umzug.ausfuehren();
      expect(ergebnis.uebersprungen, ['daten/app_daten.json']);
      expect(ergebnis.kopiert, ['daten/neu.json']);
      expect(await File(neu.pfad(['daten', 'app_daten.json'])).readAsString(), 'schon da');
      expect(await File(neu.pfad(['daten', 'kassenbuch.json'])).readAsString(), 'kasse');
    });

    test('lehnt gleichen oder verschachtelten Ordner ab', () async {
      expect(() => OrdnerUmzug(ordner, Datenordner(ordner.wurzel)).pruefen(),
          throwsArgumentError);
      expect(
          () => OrdnerUmzug(ordner, Datenordner(ordner.pfad(['unter']))).pruefen(),
          throwsArgumentError);
    });
  });

  group('Vereinskennung (0.5.0)', () {
    late Directory vtmp;
    late Datenordner o;
    setUp(() async {
      vtmp = await Directory.systemTemp.createTemp('svg_verein_test');
      o = Datenordner(vtmp.path);
    });
    tearDown(() async {
      if (await vtmp.exists()) await vtmp.delete(recursive: true);
    });

    test('leerer Ordner ist frei', () async {
      final e = await VereinsPruefung.pruefen(o, eigenerVereinsname: 'KGV Sonnenschein e. V.');
      expect(e.status, VereinsStatus.ordnerLeer);
      expect(e.darfWeiter, isTrue);
    });

    test('anlegen überschreibt nie, Kennung entscheidet', () async {
      final a = await VereinsPruefung.anlegen(o, vereinsname: 'KGV Sonnenschein e. V.', app: 'Test');
      final b = await VereinsPruefung.anlegen(o, vereinsname: 'Ganz anderer Verein');
      expect(b.kennung, a.kennung);
      expect(b.name, 'KGV Sonnenschein e. V.');
      expect((await VereinsPruefung.pruefen(o, eigenerVereinsname: 'egal', eigeneKennung: a.kennung)).status,
          VereinsStatus.gleicherVerein);
      expect((await VereinsPruefung.pruefen(o, eigenerVereinsname: 'KGV Sonnenschein e. V.', eigeneKennung: '0011223344556677')).status,
          VereinsStatus.andererVerein);
    });

    test('Name ohne Kennung: Schreibweise egal, anderer Verein wird erkannt', () async {
      await VereinsPruefung.anlegen(o, vereinsname: 'Kleingartenverein Musteranlage e. V.');
      expect((await VereinsPruefung.pruefen(o, eigenerVereinsname: 'kleingartenverein  musteranlage e.V.')).status,
          VereinsStatus.gleicherVerein);
      final e = await VereinsPruefung.pruefen(o, eigenerVereinsname: 'KGV Sonnenschein e. V.');
      expect(e.status, VereinsStatus.andererVerein);
      expect(e.darfWeiter, isFalse);
      expect(e.text, contains('Musteranlage'));
    });

    test('alte Ordner ohne verein.json: Name aus app_daten.json', () async {
      await File(o.datenDatei.path).create(recursive: true);
      await o.datenDatei.writeAsString(jsonEncode({'stammdaten': {'vereinsname': 'KGV Am Teich e. V.'}}));
      expect((await VereinsPruefung.pruefen(o, eigenerVereinsname: 'KGV Am Teich')).status,
          VereinsStatus.gleicherVerein);
      expect((await VereinsPruefung.pruefen(o, eigenerVereinsname: 'KGV Musteranlage')).status,
          VereinsStatus.andererVerein);
    });

    test('Daten ohne erkennbaren Namen: unklar', () async {
      await File(o.kassenbuchDatei.path).create(recursive: true);
      await o.kassenbuchDatei.writeAsString('{}');
      expect((await VereinsPruefung.pruefen(o, eigenerVereinsname: 'KGV Am Teich')).status,
          VereinsStatus.unklar);
    });
  });

  group('SvgSicherung', () {
    test('verschlüsseln und mit dem richtigen Passwort öffnen', () async {
      final inhalt = utf8.encode('{"buchungen":[1,2,3],"text":"Grüße"}');
      final datei = await SvgSicherung.verschluesseln(inhalt, 'geheim123',
          app: 'Test', durchlaeufe: 1000);
      expect(SvgSicherung.istSicherung(datei), isTrue);
      expect(utf8.decode(datei).contains('Grüße'), isFalse);
      expect(SvgSicherung.kopf(datei)!['app'], 'Test');
      final zurueck = await SvgSicherung.entschluesseln(datei, 'geheim123');
      expect(utf8.decode(zurueck), utf8.decode(inhalt));
    });

    test('falsches Passwort und veränderte Datei werden erkannt', () async {
      final datei = await SvgSicherung.verschluesseln(
          utf8.encode('x' * 500), 'geheim123', durchlaeufe: 1000);
      await expectLater(SvgSicherung.entschluesseln(datei, 'falsch123'),
          throwsA(isA<SicherungPasswortFalsch>()));
      final m = jsonDecode(utf8.decode(datei)) as Map<String, dynamic>;
      final d = base64Decode(m['daten'] as String);
      d[0] ^= 1;
      m['daten'] = base64Encode(d);
      await expectLater(
          SvgSicherung.entschluesseln(utf8.encode(jsonEncode(m)), 'geheim123'),
          throwsA(isA<SicherungPasswortFalsch>()));
    });

    test('zu kurzes Passwort wird abgelehnt', () {
      expect(() => SvgSicherung.verschluesseln([1], 'kurz'), throwsArgumentError);
    });
  });
}
