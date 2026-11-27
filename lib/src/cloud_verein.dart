import 'dart:convert';
import 'dart:io';

import 'cloud_daten.dart';
import 'datenordner.dart';
import 'svgcloud.dart';
import 'vereinskennung.dart';

/// Vereinsprüfung für die SVGCloud – wie [VereinsPruefung] beim Ordner:
/// `daten/verein.json` aus dem Vereinsbereich lesen, Kennung bzw. Namen
/// vergleichen, bei Bedarf anlegen. Bei einem anderen Verein wird nichts
/// geladen und nichts geschrieben.
class CloudVereinsPruefung {
  CloudVereinsPruefung._();

  static const String vereinPfad = 'daten/verein.json';

  static CloudGemeinsameDaten _datei(
          SvgCloudVerbindung verbindung, Directory zwischenspeicher) =>
      CloudGemeinsameDaten(verbindung,
          pfad: vereinPfad, zwischenspeicher: zwischenspeicher);

  /// Liest die Kennung aus der Cloud. null, wenn sie fehlt oder unlesbar ist.
  /// Fehler der Verbindung (offline, nicht gekoppelt) werden weitergereicht.
  static Future<Vereinskennung?> lesen(
      SvgCloudVerbindung verbindung, Directory zwischenspeicher) async {
    try {
      final stand = await _datei(verbindung, zwischenspeicher).lesen();
      return stand == null ? null : Vereinskennung.fromJson(stand.daten);
    } on FormatException {
      return null;
    }
  }

  /// Prüft, ob der Vereinsbereich zum eigenen Verein gehört.
  static Future<VereinsErgebnis> pruefen(
    SvgCloudVerbindung verbindung, {
    required Directory zwischenspeicher,
    required String eigenerVereinsname,
    String eigeneKennung = '',
  }) async {
    final kennung = await lesen(verbindung, zwischenspeicher);
    if (kennung != null) {
      final gleich = eigeneKennung.trim().isNotEmpty
          ? eigeneKennung.trim() == kennung.kennung
          : VereinsPruefung.gleicherName(eigenerVereinsname, kennung.name);
      return VereinsErgebnis(
        gleich ? VereinsStatus.gleicherVerein : VereinsStatus.andererVerein,
        imOrdner: kennung,
        nameImOrdner: kennung.name,
      );
    }
    final vorhanden = (await verbindung.dateiliste()).map((d) => d.pfad).toSet();
    const datendateien = [
      'daten/app_daten.json',
      'daten/kassenbuch.json',
      'daten/gartenvergabe.json',
    ];
    if (!datendateien.any(vorhanden.contains)) {
      return VereinsErgebnis(VereinsStatus.ordnerLeer);
    }
    var name = '';
    if (vorhanden.contains('daten/app_daten.json')) {
      try {
        final d = await verbindung.datei('daten/app_daten.json');
        if (d != null) {
          final roh = jsonDecode(utf8.decode(await verbindung.herunterladen(d)));
          if (roh is Map && roh['stammdaten'] is Map) {
            name = ((roh['stammdaten'] as Map)['vereinsname'] ?? '').toString().trim();
          }
        }
      } on FormatException {
        name = '';
      }
    }
    if (name.isEmpty || eigenerVereinsname.trim().isEmpty) {
      return VereinsErgebnis(VereinsStatus.unklar, nameImOrdner: name);
    }
    return VereinsErgebnis(
      VereinsPruefung.gleicherName(eigenerVereinsname, name)
          ? VereinsStatus.gleicherVerein
          : VereinsStatus.andererVerein,
      nameImOrdner: name,
    );
  }

  /// Legt die Kennung in der Cloud an, falls noch keine da ist. Eine
  /// vorhandene wird nie überschrieben, sondern zurückgegeben.
  static Future<Vereinskennung> anlegen(
    SvgCloudVerbindung verbindung, {
    required Directory zwischenspeicher,
    required String vereinsname,
    String app = '',
  }) async {
    final vorhanden = await lesen(verbindung, zwischenspeicher);
    if (vorhanden != null) return vorhanden;
    final neu = Vereinskennung(
      name: vereinsname.trim(),
      kennung: Vereinskennung.neueKennung(),
      angelegtAm: DateTime.now(),
      angelegtVon: app,
    );
    try {
      await verbindung.hochladen(
          vereinPfad, utf8.encode(const JsonEncoder.withIndent('  ').convert(neu.toJson())),
          erwarteteVersion: 0);
      return neu;
    } on SvgCloudVersionKonflikt {
      // Ein anderes Gerät war schneller: dessen Kennung gilt.
      return (await lesen(verbindung, zwischenspeicher)) ?? neu;
    }
  }
}

/// Ergebnis von [CloudUmzug.ausOrdner].
class CloudUmzugErgebnis {
  final List<String> uebertragen = [];

  /// Gab es in der Cloud schon – nicht überschrieben.
  final List<String> schonVorhanden = [];

  /// Nicht übertragen (Dateityp, Größe), mit Grund.
  final Map<String, String> uebersprungen = {};

  /// Satz für die Meldung an den Benutzer.
  String get text {
    final teile = <String>['${uebertragen.length} Datei(en) in die SVGCloud übertragen.'];
    if (schonVorhanden.isNotEmpty) {
      teile.add('${schonVorhanden.length} Datei(en) gab es dort schon; sie '
          'wurden nicht überschrieben: ${schonVorhanden.join(', ')}.');
    }
    if (uebersprungen.isNotEmpty) {
      teile.add('${uebersprungen.length} Datei(en) nicht übertragen: '
          '${uebersprungen.values.join(' ')}');
    }
    return teile.join(' ');
  }
}

/// Umzug Ordner → SVGCloud: überträgt Dateien des eigenen Bereichs mit
/// `erwarteteVersion: 0`. Existiert eine Datei in der Cloud schon, wird sie
/// nicht überschrieben, sondern gemeldet.
class CloudUmzug {
  CloudUmzug._();

  /// [pfade]: relative Pfade im Datenordner (mit „/“), z. B.
  /// `daten/kassenbuch.json`, `austausch/kassenbuch_zahlungen.json`.
  /// Fehlende Dateien werden still übergangen.
  static Future<CloudUmzugErgebnis> ausOrdner(
    Datenordner quelle,
    SvgCloudVerbindung verbindung,
    Iterable<String> pfade,
  ) async {
    final ergebnis = CloudUmzugErgebnis();
    final vorhanden = (await verbindung.dateiliste()).map((d) => d.pfad).toSet();
    for (final roh in pfade) {
      final rel = SvgCloudVerbindung.pfadNormal(roh);
      final datei = File(quelle.pfad(rel.split('/')));
      if (!await datei.exists()) continue;
      final bytes = await datei.readAsBytes();
      final unpassend = SvgCloudVerbindung.dateiPruefen(rel, bytes.length);
      if (unpassend != null) {
        ergebnis.uebersprungen[rel] = unpassend;
        continue;
      }
      if (vorhanden.contains(rel)) {
        ergebnis.schonVorhanden.add(rel);
        continue;
      }
      try {
        await verbindung.hochladen(rel, bytes, erwarteteVersion: 0);
        ergebnis.uebertragen.add(rel);
      } on SvgCloudVersionKonflikt {
        ergebnis.schonVorhanden.add(rel);
      }
    }
    return ergebnis;
  }
}

/// Pfad eines Dokuments im Vereinsbereich – genau wie
/// [Datenordner.dokumentOrdner]: `dokumente/<Kategorie>/Parzelle <Nr>/<Datei>`.
String cloudDokumentPfad(String kategorie, String parzelle, String dateiname) {
  final roh = parzelle.trim();
  final klein = roh.toLowerCase();
  final parzellenOrdner = roh.isEmpty
      ? 'Ohne Parzelle'
      : (klein.startsWith('mitglied ') || klein.startsWith('ohne parzelle'))
          ? Datenordner.dateinameSicher(roh)
          : 'Parzelle ${Datenordner.dateinameSicher(roh)}';
  return [
    'dokumente',
    Datenordner.dateinameSicher(kategorie),
    parzellenOrdner,
    Datenordner.dateinameSicher(dateiname),
  ].join('/');
}
