import 'dart:io';

/// Wo eine App ihre Daten ablegt. Wird bei der Einrichtung abgefragt.
enum Speicherart {
  /// Nur auf diesem Gerät (App-Dokumentenordner).
  lokal,

  /// Gemeinsamer Ordner: NAS, Speicher an der FRITZ!Box, OneDrive, iCloud,
  /// MagentaCloud …
  ordner,

  /// Cloud des Stadtverbands (folgt später).
  svgCloud,
}

/// Die Einstellung eines Geräts. Sie wird pro Gerät gespeichert
/// (z. B. in SharedPreferences) und nie in die gemeinsame Datei geschrieben,
/// denn jeder Rechner erreicht denselben Ordner unter einem anderen Pfad.
class DatenordnerEinstellung {
  const DatenordnerEinstellung({required this.speicherart, this.pfad = ''});

  static const DatenordnerEinstellung nurLokal =
      DatenordnerEinstellung(speicherart: Speicherart.lokal);

  final Speicherart speicherart;

  /// Pfad zum gemeinsamen Ordner (nur bei [Speicherart.ordner]).
  final String pfad;

  bool get istGemeinsam =>
      speicherart == Speicherart.ordner && pfad.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'speicherart': speicherart.name,
        'pfad': pfad,
      };

  factory DatenordnerEinstellung.fromJson(Map<String, dynamic> json) {
    final name = (json['speicherart'] ?? '').toString();
    final art = Speicherart.values.firstWhere(
      (e) => e.name == name,
      orElse: () => Speicherart.lokal,
    );
    return DatenordnerEinstellung(
      speicherart: art,
      pfad: (json['pfad'] ?? '').toString(),
    );
  }
}

/// Pfade im Datenordner. Für „lokal“ wird einfach der App-Dokumentenordner
/// als Wurzel übergeben – dann gilt derselbe Aufbau auch auf dem Gerät.
class Datenordner {
  Datenordner(String wurzel)
      : wurzel = wurzel.trim().replaceAll(RegExp(r'[/\\]+$'), '');

  final String wurzel;

  static const String datenDateiName = 'app_daten.json';

  String pfad(List<String> teile) {
    var ergebnis = wurzel;
    for (final teil in teile.map((e) => e.trim()).where((e) => e.isNotEmpty)) {
      ergebnis = '$ergebnis${Platform.pathSeparator}$teil';
    }
    return ergebnis;
  }

  File get datenDatei => File(pfad(['daten', datenDateiName]));

  /// Eigene Datendatei des Kassenbuchs (ab 0.2.0). Liegt neben
  /// app_daten.json, damit Buchungen und Änderungsprotokoll die gemeinsame
  /// Datei der anderen Apps nicht aufblähen.
  static const String kassenbuchDateiName = 'kassenbuch.json';

  File get kassenbuchDatei => File(pfad(['daten', kassenbuchDateiName]));

  /// Eigene Datendatei der Gartenvergabe (Vergaben, Löschvermerke).
  static const String gartenvergabeDateiName = 'gartenvergabe.json';

  File get gartenvergabeDatei =>
      File(pfad(['daten', gartenvergabeDateiName]));

  /// Austausch zwischen Kleingartenverwaltung und Kassenbuch (ab 0.3.0).
  /// Jede App schreibt nur ihre eigene Datei und liest die der anderen.
  Directory get austauschOrdner => Directory(pfad(['austausch']));

  /// Schreibt die Kleingartenverwaltung: Debitoren, Rechnungen mit
  /// Positionen und Kostenart, Stornos, Ratenpläne.
  File get verwaltungForderungenDatei =>
      File(pfad(['austausch', 'verwaltung_forderungen.json']));

  /// Schreibt das Kassenbuch: Zahlungen mit Zuordnung zur Rechnung,
  /// Beträge der Eingangsrechnungen Strom und Wasser.
  File get kassenbuchZahlungenDatei =>
      File(pfad(['austausch', 'kassenbuch_zahlungen.json']));

  /// Beliebige Datei im Ordner daten/ (z. B. für weitere Apps).
  File datenDateiMitNamen(String name) => File(pfad(['daten', name]));
  File get schreibsperreDatei => File(pfad(['locks', 'schreibsperre.json']));
  File get sitzungsDatei => File(pfad(['locks', 'aktive_sitzungen.json']));

  Directory get rechnungenOrdner => Directory(pfad(['rechnungen']));

  /// Dokumentenordner einer Parzelle – genau wie in der Kleingartenverwaltung:
  /// dokumente/<Kategorie>/Parzelle <Nr>/
  ///
  /// Bitte ohne [datum] verwenden: Die Kleingartenverwaltung zeigt nur Dateien,
  /// die direkt in „Parzelle <Nr>“ liegen. Das Datum gehört in den Dateinamen.
  /// [datum] bleibt nur aus Kompatibilitätsgründen erhalten.
  ///
  /// Die Kleingartenverwaltung zeigt jede Kategorie, in der es einen Ordner
  /// „Parzelle <Nr>“ gibt, automatisch unter den Dokumenten dieser Parzelle an.
  /// Beispiele: Kategorie „Begehung“ (Gartenbegehung), „Pachtvertrag“
  /// (Gartenvergabe).
  ///
  /// [parzelle] bitte so übergeben, wie sie in app_daten.json steht
  /// (gaerten[].parzelle), damit der Ordnername exakt passt.
  Directory dokumentOrdner(String kategorie, String parzelle, {DateTime? datum}) {
    final roh = parzelle.trim();
    final klein = roh.toLowerCase();
    final parzellenOrdner = roh.isEmpty
        ? 'Ohne Parzelle'
        : (klein.startsWith('mitglied ') || klein.startsWith('ohne parzelle'))
            ? dateinameSicher(roh)
            : 'Parzelle ${dateinameSicher(roh)}';
    final teile = ['dokumente', dateinameSicher(kategorie), parzellenOrdner];
    if (datum != null) {
      teile.add('${datum.year.toString().padLeft(4, '0')}-'
          '${datum.month.toString().padLeft(2, '0')}-'
          '${datum.day.toString().padLeft(2, '0')}');
    }
    return Directory(pfad(teile));
  }

  /// Liefert einen freien Dateinamen im [ordner]: „Bericht.pdf“, sonst
  /// „Bericht (2).pdf“, „Bericht (3).pdf“ … – es wird nie etwas überschrieben.
  static Future<File> freieDatei(Directory ordner, String dateiname) async {
    await ordner.create(recursive: true);
    final sauber = dateinameSicher(dateiname);
    final punkt = sauber.lastIndexOf('.');
    final stamm = punkt > 0 ? sauber.substring(0, punkt) : sauber;
    final endung = punkt > 0 ? sauber.substring(punkt) : '';
    var datei = File('${ordner.path}${Platform.pathSeparator}$sauber');
    var n = 2;
    while (await datei.exists()) {
      datei = File('${ordner.path}${Platform.pathSeparator}$stamm ($n)$endung');
      n++;
    }
    return datei;
  }

  Future<bool> erreichbar() async {
    if (wurzel.isEmpty) return false;
    try {
      return await Directory(wurzel).exists();
    } on FileSystemException {
      return false;
    }
  }

  /// Legt die Grundordner an (bestehende bleiben unberührt).
  Future<void> grundordnerAnlegen() async {
    for (final teil in const [
      'daten',
      'austausch',
      'locks',
      'dokumente',
      'rechnungen',
      'backups',
      'protokoll',
    ]) {
      await Directory(pfad([teil])).create(recursive: true);
    }
  }

  /// Gültiger Datei-/Ordnername – dieselbe Regel wie in der
  /// Kleingartenverwaltung (_saubererDateiname), damit Ordnernamen gleich sind.
  static String dateinameSicher(String text) {
    final sauber = text.trim().replaceAll(RegExp(r'[\/:*?"<>|]'), '_');
    return sauber.isEmpty ? 'datei' : sauber;
  }
}
