// Geräte-Test der SVGCloud-Vereinsordner-API: Koppeln, Liste, Hochladen,
// Herunterladen, Ändern und Konflikt. Legt nur Dateien unter
// _geraetetest/ an; Vereinsdaten werden nicht angefasst.
//
// Aufruf im Paketordner:
//   dart run tool/svgcloud_geraetetest.dart --schluessel <Verbindungsschlüssel>
//   dart run tool/svgcloud_geraetetest.dart            (danach, Token ist gemerkt)
//   dart run tool/svgcloud_geraetetest.dart --roh      (Inhalt ohne multipart senden)
//   dart run tool/svgcloud_geraetetest.dart --vergessen (gemerkten Token löschen)

import 'dart:convert';
import 'dart:io';

import 'package:svg_datenordner/svg_datenordner.dart';

class DateiTokenSpeicher implements SvgCloudTokenSpeicher {
  DateiTokenSpeicher(this.datei);
  final File datei;
  @override
  Future<String?> lesen() async => await datei.exists() ? (await datei.readAsString()).trim() : null;
  @override
  Future<void> speichern(String token) async {
    await datei.writeAsString(token);
    if (!Platform.isWindows) await Process.run('chmod', ['600', datei.path]);
  }

  @override
  Future<void> loeschen() async {
    if (await datei.exists()) await datei.delete();
  }
}

Future<void> main(List<String> args) async {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  final speicher = DateiTokenSpeicher(File('$home/.svgcloud_geraetetest_token'));
  if (args.contains('--vergessen')) {
    await speicher.loeschen();
    print('Gemerkter Test-Token gelöscht.');
    return;
  }
  final cloud = SvgCloudVerbindung(tokenSpeicher: speicher);
  if (args.contains('--roh')) cloud.hochladeArt = SvgCloudHochladeArt.roh;

  var fehler = 0;
  Future<T?> schritt<T>(String name, Future<T> Function() f) async {
    stdout.write('• $name … ');
    try {
      final r = await f();
      print('OK');
      return r;
    } on SvgCloudFehler catch (e) {
      fehler++;
      print('FEHLER: ${e.meldung}${e.status == null ? '' : ' (HTTP ${e.status})'}');
      return null;
    } catch (e) {
      fehler++;
      print('FEHLER: $e');
      return null;
    }
  }

  final i = args.indexOf('--schluessel');
  if (i >= 0 && i + 1 < args.length) {
    await schritt('Gerät koppeln', () => cloud.koppeln(args[i + 1], geraetename: 'Gerätetest ${Platform.localHostname}', app: 'Geraetetest'));
  }
  if (!await cloud.istGekoppelt()) {
    print('Nicht gekoppelt. Bitte mit --schluessel <Verbindungsschlüssel> aufrufen.');
    exit(1);
  }
  final ping = await schritt('Verbindung prüfen (ping)', cloud.pruefen);
  if (ping != null) print('    Antwort: ${jsonEncode(ping)}');

  final liste = await schritt('Dateiliste lesen', cloud.dateiliste);
  if (liste != null) {
    print('    ${liste.length} Dateien im Vereinsordner');
    for (final d in liste.take(15)) {
      print('    - ${d.pfad}  (Version ${d.version}, ${d.groesse} Bytes)');
    }
  }

  final stempel = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
  final pfad = '_geraetetest/test_$stempel.txt';
  const text1 = 'SVGCloud Gerätetest – erste Fassung äöüß';
  const text2 = 'SVGCloud Gerätetest – zweite Fassung';

  final d1 = await schritt('Neue Datei hochladen ($pfad, expected_version=0)',
      () => cloud.hochladen(pfad, utf8.encode(text1), erwarteteVersion: 0));
  if (d1 != null) print('    Version laut Server: ${d1.version}');

  final inhalt = await schritt('Datei wieder lesen', () => cloud.herunterladenPfad(pfad));
  if (inhalt != null) {
    final gelesen = utf8.decode(inhalt, allowMalformed: true);
    if (gelesen == text1) {
      print('    Inhalt stimmt überein (auch Umlaute).');
    } else {
      fehler++;
      print('    ABWEICHUNG – gelesen: ${gelesen.length > 200 ? '${gelesen.substring(0, 200)}…' : gelesen}');
    }
  }

  final v1 = d1?.version ?? 1;
  final d2 = await schritt('Datei ändern (expected_version=$v1)',
      () => cloud.hochladen(pfad, utf8.encode(text2), erwarteteVersion: v1));
  if (d2 != null) print('    Version laut Server: ${d2.version}');

  stdout.write('• Konflikt prüfen (nochmals mit veralteter expected_version=$v1) … ');
  try {
    await cloud.hochladen(pfad, utf8.encode('darf nicht ankommen'), erwarteteVersion: v1);
    fehler++;
    print('FEHLER: Server hat die veraltete Fassung angenommen – 409 fehlt.');
  } on SvgCloudVersionKonflikt catch (k) {
    print('OK (409, aktuelle Version: ${k.aktuelleVersion ?? 'nicht mitgeteilt'})');
  } on SvgCloudFehler catch (e) {
    fehler++;
    print('FEHLER: ${e.meldung} (HTTP ${e.status})');
  }

  final d3 = await schritt('Dokument ablegen ohne Überschreiben', () async {
    return cloudDokumentAblegen(cloud, pfad, utf8.encode('Kopie'));
  });
  if (d3 != null) print('    abgelegt als: ${d3.pfad}');

  print('');
  print(fehler == 0
      ? 'Alles bestanden. Die Testdateien liegen unter _geraetetest/ und können auf dem Server gelöscht werden.'
      : '$fehler Schritt(e) fehlgeschlagen – bitte diese Ausgabe an Andreas bzw. den Datensync-Chat geben.');
  exit(fehler == 0 ? 0 : 2);
}
