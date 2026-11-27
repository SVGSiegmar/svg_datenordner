import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'gemeinsame_daten.dart';
import 'svgcloud.dart';

/// Gegenstück zu [GemeinsameDaten] für die SVGCloud: liest und ändert eine
/// JSON-Datei des Vereins (z. B. `daten/app_daten.json`) direkt über die
/// Datei-API.
///
/// - Die „Prüfsumme“ im [DatenStand] ist hier die Serverversion (`v12`).
///   Apps können sie genauso wie bisher als `erwartetePruefsumme` übergeben.
/// - Konflikte meldet der Server über die Versionsnummer; dann wird wie
///   bisher [DatenWurdenGeaendert] geworfen und nichts überschrieben.
/// - Jeder gelesene Stand wird in [zwischenspeicher] abgelegt. Ohne Netz
///   liefert [lesen] diesen Stand (mit [offline] = true), damit die App
///   weiterarbeiten kann. Ein Speichern ohne Netz merkt sich die Änderung als
///   „ausstehend“; [nachholen] lädt sie hoch, sobald die Verbindung wieder da
///   ist – mit Versionsprüfung, also nie über eine fremde Änderung hinweg.
class CloudGemeinsameDaten {
  CloudGemeinsameDaten(
    this.verbindung, {
    required this.pfad,
    required this.zwischenspeicher,
  });

  final SvgCloudVerbindung verbindung;

  /// Pfad im Vereinsbereich, z. B. `daten/app_daten.json`.
  final String pfad;

  /// Lokaler Ordner nur für diese App (z. B. im Datenbereich der App), in dem
  /// der zuletzt gelesene Stand und ausstehende Änderungen liegen.
  final Directory zwischenspeicher;

  static const JsonEncoder _encoder = JsonEncoder.withIndent('  ');

  /// true, wenn der letzte [lesen]-Aufruf ohne Netz aus dem Zwischenspeicher kam.
  bool offline = false;

  String get _p => SvgCloudVerbindung.pfadNormal(pfad);
  File get _stand => File('${zwischenspeicher.path}${Platform.pathSeparator}'
      '${_p.replaceAll('/', '__')}.stand.json');
  File get _ausstehend => File('${zwischenspeicher.path}${Platform.pathSeparator}'
      '${_p.replaceAll('/', '__')}.ausstehend.json');

  static String pruefsummeAusVersion(int version) => version <= 0 ? '' : 'v$version';
  static int versionAusPruefsumme(String p) =>
      p.startsWith('v') ? (int.tryParse(p.substring(1)) ?? 0) : 0;

  /// Liest den aktuellen Stand. null, wenn die Datei in der Cloud noch fehlt.
  Future<DatenStand?> lesen() async {
    try {
      final d = await verbindung.datei(_p);
      offline = false;
      if (d == null) return null;
      final text = utf8.decode(await verbindung.herunterladen(d));
      final daten = _alsMap(text);
      await _merken(d.version, text);
      return DatenStand(daten, pruefsummeAusVersion(d.version));
    } on SvgCloudOffline {
      final gemerkt = await _gemerkt();
      if (gemerkt == null) rethrow;
      offline = true;
      return gemerkt;
    }
  }

  /// Neu lesen – Änderung einfügen – mit Versionsprüfung hochladen.
  ///
  /// [erwartetePruefsumme]: wie bei [GemeinsameDaten.aendern]; stimmt die
  /// Serverversion nicht, wird [DatenWurdenGeaendert] geworfen.
  /// Ohne Netz wird die Änderung auf dem zuletzt gelesenen Stand ausgeführt,
  /// als ausstehend gemerkt und [SvgCloudOffline] geworfen; die App zeigt
  /// dann „wird gespeichert, sobald die Verbindung wieder da ist“.
  Future<DatenStand> aendern(
    FutureOr<void> Function(Map<String, dynamic> daten) aenderung, {
    bool neuAnlegenErlaubt = false,
    String? erwartetePruefsumme,
  }) async {
    DatenStand? stand;
    try {
      stand = await lesen();
    } on SvgCloudOffline {
      stand = null;
      offline = true;
    }
    if (offline) {
      final basis = await _gemerkt();
      if (basis == null && !neuAnlegenErlaubt) rethrowOffline();
      final daten = basis?.daten ?? <String, dynamic>{};
      await aenderung(daten);
      await _ausstehendMerken(versionAusPruefsumme(basis?.pruefsumme ?? ''), _encoder.convert(daten));
      throw SvgCloudOffline();
    }
    if (erwartetePruefsumme != null && (stand?.pruefsumme ?? '') != erwartetePruefsumme) {
      throw DatenWurdenGeaendert(_p);
    }
    if (stand == null && !neuAnlegenErlaubt) {
      throw StateError('$_p fehlt in der SVGCloud.');
    }
    final daten = stand?.daten ?? <String, dynamic>{};
    await aenderung(daten);
    return _hochladen(versionAusPruefsumme(stand?.pruefsumme ?? ''), _encoder.convert(daten));
  }

  /// Gibt es eine ohne Netz gespeicherte Änderung, die noch hochgeladen werden muss?
  Future<bool> hatAusstehendes() => _ausstehend.exists();

  /// Lädt eine ohne Netz gespeicherte Änderung hoch. Hat inzwischen ein
  /// anderes Gerät gespeichert, wird [DatenWurdenGeaendert] geworfen; die
  /// ausstehende Fassung bleibt dann liegen ([ausstehendeFassung]), damit die
  /// App wie bisher fragen kann („Neu laden“ oder „Meine Fassung speichern“).
  Future<DatenStand?> nachholen() async {
    if (!await _ausstehend.exists()) return null;
    final roh = jsonDecode(await _ausstehend.readAsString()) as Map<String, dynamic>;
    final ergebnis = await _hochladen((roh['basisVersion'] as num?)?.toInt() ?? 0, roh['text'] as String);
    await _ausstehend.delete();
    return ergebnis;
  }

  /// Die ausstehende Fassung (oder null), z. B. um sie nach einem Konflikt
  /// mit „Meine Fassung speichern“ doch zu übernehmen.
  Future<Map<String, dynamic>?> ausstehendeFassung() async {
    if (!await _ausstehend.exists()) return null;
    final roh = jsonDecode(await _ausstehend.readAsString()) as Map<String, dynamic>;
    return _alsMap(roh['text'] as String);
  }

  /// Verwirft die ausstehende Fassung (nach „Neu laden“).
  Future<void> ausstehendVerwerfen() async {
    if (await _ausstehend.exists()) await _ausstehend.delete();
  }

  // ---------------------------------------------------------------- intern

  Never rethrowOffline() => throw SvgCloudOffline();

  Future<DatenStand> _hochladen(int basisVersion, String text) async {
    try {
      final d = await verbindung.hochladen(_p, utf8.encode(text), erwarteteVersion: basisVersion);
      await _merken(d.version, text);
      return DatenStand(_alsMap(text), pruefsummeAusVersion(d.version));
    } on SvgCloudVersionKonflikt {
      throw DatenWurdenGeaendert(_p);
    }
  }

  Map<String, dynamic> _alsMap(String text) {
    if (text.trim().isEmpty) {
      throw FormatException('$_p ist leer und wird nicht überschrieben.');
    }
    final roh = jsonDecode(text);
    if (roh is! Map) throw FormatException('$_p hat kein gültiges Format.');
    return Map<String, dynamic>.from(roh);
  }

  Future<void> _merken(int version, String text) async {
    await zwischenspeicher.create(recursive: true);
    await _schreiben(_stand, jsonEncode({'version': version, 'text': text}));
  }

  Future<DatenStand?> _gemerkt() async {
    if (!await _stand.exists()) return null;
    try {
      final roh = jsonDecode(await _stand.readAsString()) as Map<String, dynamic>;
      final v = (roh['version'] as num?)?.toInt() ?? 0;
      return DatenStand(_alsMap(roh['text'] as String), pruefsummeAusVersion(v));
    } catch (_) {
      return null;
    }
  }

  Future<void> _ausstehendMerken(int basisVersion, String text) async {
    await zwischenspeicher.create(recursive: true);
    // Eine ältere ausstehende Fassung behält ihre Basisversion: Die neue
    // Fassung baut auf ihr auf.
    var basis = basisVersion;
    if (await _ausstehend.exists()) {
      try {
        final alt = jsonDecode(await _ausstehend.readAsString()) as Map<String, dynamic>;
        basis = (alt['basisVersion'] as num?)?.toInt() ?? basis;
      } catch (_) {}
    }
    await _schreiben(_ausstehend, jsonEncode({
      'basisVersion': basis,
      'gespeichertAm': DateTime.now().toIso8601String(),
      'text': text,
    }));
    // Auch der lokale Stand zeigt ab jetzt die eigene Fassung.
    await _schreiben(_stand, jsonEncode({'version': basis, 'text': text}));
  }

  static Future<void> _schreiben(File ziel, String text) async {
    final hilf = File('${ziel.path}.tmp-$pid');
    await hilf.writeAsString(text, flush: true);
    await hilf.rename(ziel.path);
  }
}

/// Legt ein Dokument (PDF o. ä.) im Vereinsbereich ab, ohne eine
/// vorhandene Datei zu überschreiben: Gibt es den Namen schon, wird
/// „(2)“, „(3)“ … angehängt. Liefert die abgelegte Datei.
Future<CloudDatei> cloudDokumentAblegen(
  SvgCloudVerbindung verbindung,
  String pfad,
  List<int> inhalt,
) async {
  final p = SvgCloudVerbindung.pfadNormal(pfad);
  final unpassend = SvgCloudVerbindung.dateiPruefen(p, inhalt.length);
  if (unpassend != null) throw SvgCloudFehler(unpassend);
  final vorhanden = (await verbindung.dateiliste()).map((d) => d.pfad).toSet();
  final punkt = p.lastIndexOf('.');
  final stamm = punkt > p.lastIndexOf('/') ? p.substring(0, punkt) : p;
  final endung = punkt > p.lastIndexOf('/') ? p.substring(punkt) : '';
  var kandidat = p;
  for (var n = 2; vorhanden.contains(kandidat); n++) {
    kandidat = '$stamm ($n)$endung';
  }
  return verbindung.hochladen(kandidat, inhalt, erwarteteVersion: 0);
}
