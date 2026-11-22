import 'dart:io';

import 'datenordner.dart';

/// Was im bisherigen Ordner liegt – für die Rückfrage vor dem Umzug.
class UmzugBestand {
  UmzugBestand({
    required this.datendateien,
    required this.rechnungen,
    required this.dokumente,
    required this.sonstige,
    required this.bytes,
    required this.schonImZiel,
  });

  /// Dateien in daten/ und austausch/.
  final int datendateien;

  /// Dateien in rechnungen/.
  final int rechnungen;

  /// Dateien in dokumente/.
  final int dokumente;

  /// Alle übrigen Dateien (Sicherungen, Logos, Ordner anderer Apps …).
  final int sonstige;

  /// Gesamtgröße in Bytes.
  final int bytes;

  /// Relative Pfade, die es im Ziel schon gibt. Sie werden beim Umzug
  /// übersprungen, nie überschrieben.
  final List<String> schonImZiel;

  int get gesamt => datendateien + rechnungen + dokumente + sonstige;

  bool get leer => gesamt == 0;

  /// Kurzer Text für die Rückfrage, z. B.
  /// „4 Datendateien, 78 Rechnungen, 18 Dokumente und 12 weitere Dateien“.
  String get beschreibung {
    final teile = <String>[
      if (datendateien > 0)
        '$datendateien ${datendateien == 1 ? 'Datendatei' : 'Datendateien'}',
      if (rechnungen > 0)
        '$rechnungen ${rechnungen == 1 ? 'Rechnung' : 'Rechnungen'}',
      if (dokumente > 0)
        '$dokumente ${dokumente == 1 ? 'Dokument' : 'Dokumente'}',
      if (sonstige > 0)
        '$sonstige ${sonstige == 1 ? 'weitere Datei' : 'weitere Dateien'}',
    ];
    if (teile.isEmpty) return 'keine Dateien';
    if (teile.length == 1) return teile.first;
    return '${teile.sublist(0, teile.length - 1).join(', ')} und ${teile.last}';
  }
}

/// Ergebnis des Umzugs.
class UmzugErgebnis {
  UmzugErgebnis();

  /// Kopierte Dateien (relative Pfade).
  final List<String> kopiert = [];

  /// Im Ziel schon vorhanden und deshalb nicht angefasst.
  final List<String> uebersprungen = [];

  /// Dateien, die nicht kopiert werden konnten, mit Grund.
  final List<String> fehler = [];

  bool get fehlerfrei => fehler.isEmpty;
}

/// Nimmt beim Wechsel des Datenordners den Inhalt des bisherigen Ordners mit
/// (ab 0.4.0) – damit kein Verein dafür Terminal oder Finder braucht.
///
/// Regeln wie `rsync --ignore-existing`:
/// - Ordner werden zusammengeführt.
/// - Eine Datei, die es im Ziel schon gibt, wird nie überschrieben.
/// - Sperrdateien, Papierkorb und Hilfsdateien werden ausgelassen.
/// - Der bisherige Ordner bleibt unverändert als Sicherung liegen.
class OrdnerUmzug {
  OrdnerUmzug(this.quelle, this.ziel);

  final Datenordner quelle;
  final Datenordner ziel;

  /// Ordner, die nie mitgenommen werden (auf jeder Ebene).
  static const ausgelasseneOrdner = {
    'locks',
    'temp',
    '#recycle',
    '@eaDir',
    '.Trash',
    '.Trashes',
    '.Spotlight-V100',
    '.fseventsd',
  };

  /// Einzelne Dateien, die nie mitgenommen werden.
  static bool _dateiAuslassen(String name) =>
      name == '.DS_Store' ||
      name == 'Thumbs.db' ||
      name == 'desktop.ini' ||
      name.startsWith('._') ||
      name.endsWith('.lock') ||
      name.contains('.tmp-');

  String get _q => _normal(quelle.wurzel);
  String get _z => _normal(ziel.wurzel);

  static String _normal(String pfad) =>
      pfad.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');

  /// Wirft [ArgumentError], wenn Quelle und Ziel gleich sind oder ineinander
  /// liegen (sonst würde der Umzug sich selbst kopieren).
  void _pruefePfade() {
    final q = _q.toLowerCase();
    final z = _z.toLowerCase();
    if (q.isEmpty || z.isEmpty) {
      throw ArgumentError('Quell- und Zielordner müssen angegeben sein.');
    }
    if (q == z) {
      throw ArgumentError('Der neue Datenordner ist derselbe wie der bisherige.');
    }
    if (z.startsWith('$q/') || q.startsWith('$z/')) {
      throw ArgumentError(
        'Der neue Datenordner darf nicht im bisherigen liegen und umgekehrt.',
      );
    }
  }

  /// Alle mitzunehmenden Dateien als relative Pfade (mit „/“ getrennt).
  Future<List<String>> _dateien() async {
    final wurzel = Directory(quelle.wurzel);
    if (!await wurzel.exists()) return const [];
    final ergebnis = <String>[];
    Future<void> gehe(Directory ordner, String relativ) async {
      await for (final e in ordner.list(followLinks: false)) {
        final name = e.path
            .replaceAll('\\', '/')
            .split('/')
            .where((t) => t.isNotEmpty)
            .last;
        final pfad = relativ.isEmpty ? name : '$relativ/$name';
        if (e is Directory) {
          if (ausgelasseneOrdner.contains(name)) continue;
          await gehe(e, pfad);
        } else if (e is File) {
          if (_dateiAuslassen(name)) continue;
          ergebnis.add(pfad);
        }
      }
    }

    await gehe(wurzel, '');
    ergebnis.sort();
    return ergebnis;
  }

  static File _datei(String wurzel, String relativ) => File(
        '$wurzel${Platform.pathSeparator}'
        '${relativ.replaceAll('/', Platform.pathSeparator)}',
      );

  File _inQuelle(String relativ) => _datei(quelle.wurzel, relativ);

  File _inZiel(String relativ) => _datei(ziel.wurzel, relativ);

  /// Zählt, was mitgenommen würde, und welche Dateien im Ziel schon liegen.
  Future<UmzugBestand> pruefen() async {
    _pruefePfade();
    var daten = 0, rechnungen = 0, dokumente = 0, sonstige = 0, bytes = 0;
    final schonDa = <String>[];
    for (final rel in await _dateien()) {
      final oben = rel.split('/').first;
      if (oben == 'daten' || oben == 'austausch') {
        daten++;
      } else if (oben == 'rechnungen') {
        rechnungen++;
      } else if (oben == 'dokumente') {
        dokumente++;
      } else {
        sonstige++;
      }
      try {
        bytes += await _inQuelle(rel).length();
      } on FileSystemException {
        // Größe unbekannt – zählt trotzdem
      }
      if (await _inZiel(rel).exists()) schonDa.add(rel);
    }
    return UmzugBestand(
      datendateien: daten,
      rechnungen: rechnungen,
      dokumente: dokumente,
      sonstige: sonstige,
      bytes: bytes,
      schonImZiel: schonDa,
    );
  }

  /// Kopiert alles, was im Ziel noch fehlt. [fortschritt] meldet
  /// (erledigt, gesamt) nach jeder Datei.
  Future<UmzugErgebnis> ausfuehren({
    void Function(int erledigt, int gesamt)? fortschritt,
  }) async {
    _pruefePfade();
    final ergebnis = UmzugErgebnis();
    final dateien = await _dateien();
    var erledigt = 0;
    for (final rel in dateien) {
      final zielDatei = _inZiel(rel);
      try {
        if (await zielDatei.exists()) {
          ergebnis.uebersprungen.add(rel);
        } else {
          await zielDatei.parent.create(recursive: true);
          final quellDatei = _inQuelle(rel);
          // Erst unter Hilfsnamen kopieren, dann umbenennen: Bricht der
          // Umzug ab, liegt im Ziel nie eine halbe Datei unter echtem Namen.
          final hilf = File('${zielDatei.path}.tmp-umzug-$pid');
          await quellDatei.copy(hilf.path);
          try {
            await hilf.rename(zielDatei.path);
          } on FileSystemException {
            await quellDatei.copy(zielDatei.path);
            try {
              await hilf.delete();
            } on FileSystemException {
              // bleibt liegen, schadet nicht
            }
          }
          try {
            await zielDatei.setLastModified(await quellDatei.lastModified());
          } on FileSystemException {
            // manche Netzlaufwerke erlauben das nicht – egal
          }
          ergebnis.kopiert.add(rel);
        }
      } on FileSystemException catch (f) {
        ergebnis.fehler.add('$rel: ${f.message}');
      }
      erledigt++;
      fortschritt?.call(erledigt, dateien.length);
    }
    await ziel.grundordnerAnlegen();
    return ergebnis;
  }
}
