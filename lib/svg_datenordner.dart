/// Gemeinsamer Datenordner für die Vereins-Apps.
///
/// Aufbau des Ordners (identisch zur Kleingartenverwaltung ab 8.0.4):
///
/// ```
/// <Datenordner>/
///   daten/app_daten.json       Verein, Parzellen, Mitglieder
///   daten/kassenbuch.json      Kassenbuch (ab 0.2.0)
///   daten/verein.json          Vereinskennung (ab 0.5.0)
///   locks/                     aktive_sitzungen.json, schreibsperre.json
///   dokumente/<Kategorie>/Parzelle <Nr>/ (ohne Datumsordner)
///                              z. B. Begehung (Gartenbegehung),
///                              Pachtvertrag (Gartenvergabe)
///   rechnungen/, backups/, protokoll/
/// ```
library svg_datenordner;

export 'src/datenordner.dart';
export 'src/gemeinsame_daten.dart';
export 'src/kgv_daten.dart';
export 'src/ordner_umzug.dart';
export 'src/schreibsperre.dart';
export 'src/vereinskennung.dart';
export 'src/import_regeln.dart';
export 'src/sicherung.dart';
