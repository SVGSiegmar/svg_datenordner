/// Gemeinsamer Datenordner für die Vereins-Apps.
///
/// Aufbau des Ordners (identisch zur Kleingartenverwaltung ab 8.0.4):
///
/// ```
/// <Datenordner>/
///   daten/app_daten.json       Verein, Parzellen, Mitglieder
///   locks/                     aktive_sitzungen.json, schreibsperre.json
///   dokumente/<Kategorie>/Parzelle <Nr>/<Datum>/
///                              z. B. Begehung (Gartenbegehung),
///                              Pachtvertrag (Gartenvergabe)
///   rechnungen/, backups/, protokoll/
/// ```
library svg_datenordner;

export 'src/datenordner.dart';
export 'src/gemeinsame_daten.dart';
export 'src/kgv_daten.dart';
export 'src/schreibsperre.dart';
