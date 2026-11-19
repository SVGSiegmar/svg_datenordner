import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'datenordner.dart';
import 'schreibsperre.dart';

/// Ein gelesener Stand der gemeinsamen Datei.
class DatenStand {
  DatenStand(this.daten, this.pruefsumme);

  /// Der komplette Inhalt, auch Bereiche, die diese App nicht kennt.
  final Map<String, dynamic> daten;

  /// SHA-256 des Dateitexts – dieselbe Prüfsumme wie in der
  /// Kleingartenverwaltung. Damit lässt sich erkennen, ob ein anderer
  /// Rechner inzwischen gespeichert hat.
  final String pruefsumme;
}

/// Wird geworfen, wenn die Datei seit dem letzten Lesen von einer anderen
/// App oder einem anderen Rechner gespeichert wurde (siehe
/// `erwartetePruefsumme` in [GemeinsameDaten.aendern]). Die Datei bleibt
/// dann unverändert.
class DatenWurdenGeaendert implements Exception {
  DatenWurdenGeaendert(this.datei);

  final String datei;

  @override
  String toString() =>
      'DatenWurdenGeaendert: $datei wurde inzwischen an anderer Stelle gespeichert.';
}

/// Lesen und Ändern von daten/app_daten.json – oder, ab 0.2.0, einer
/// anderen Datei im Datenordner (z. B. [Datenordner.kassenbuchDatei]).
///
/// Regel für alle Apps: **neu lesen – Änderung einfügen – schreiben**, und das
/// unter der kurzen [Schreibsperre]. Eine App schreibt nie ihr gesamtes
/// Bild zurück, sondern ändert nur, was sie ändern will. Alles andere bleibt
/// genau so erhalten, wie es in der Datei steht.
class GemeinsameDaten {
  GemeinsameDaten(
    this.ordner, {
    required this.app,
    this.benutzer = '',
    File? datei,
  }) : datei = datei ?? ordner.datenDatei;

  final Datenordner ordner;

  /// Die Datei, die gelesen und geändert wird. Standard: app_daten.json.
  /// Alle Dateien eines Ordners teilen sich dieselbe [Schreibsperre].
  final File datei;

  /// Name der App, steht in der Sperrdatei (z. B. „Gartenvergabe“).
  final String app;
  final String benutzer;

  static const JsonEncoder _encoder = JsonEncoder.withIndent('  ');

  static String pruefsummeVon(String text) =>
      sha256.convert(utf8.encode(text)).toString();

  /// Liest die Datei. Liefert null, wenn es sie noch nicht gibt.
  /// Wirft [FormatException], wenn sie leer oder kaputt ist – sie wird dann
  /// bewusst nicht überschrieben.
  Future<DatenStand?> lesen() async {
    if (!await datei.exists()) return null;
    final text = await datei.readAsString();
    if (text.trim().isEmpty) {
      throw const FormatException(
        'Die gemeinsame Datendatei ist leer. Sie wird nicht überschrieben.',
      );
    }
    final roh = jsonDecode(text);
    if (roh is! Map) {
      throw const FormatException(
        'Die gemeinsame Datendatei hat kein gültiges Format.',
      );
    }
    return DatenStand(Map<String, dynamic>.from(roh), pruefsummeVon(text));
  }

  /// true, wenn seit [bekanntePruefsumme] jemand anderes gespeichert hat.
  Future<bool> wurdeGeaendert(String bekanntePruefsumme) async {
    if (!await datei.exists()) return bekanntePruefsumme.isNotEmpty;
    return pruefsummeVon(await datei.readAsString()) != bekanntePruefsumme;
  }

  /// Ändert die Datei sicher: Sperre holen, frisch lesen, [aenderung]
  /// ausführen, schreiben, Sperre freigeben.
  ///
  /// [aenderung] bekommt den frisch gelesenen Inhalt und ändert ihn direkt.
  /// Wirft [SchreibsperreBelegt], wenn eine andere App zu lange speichert.
  ///
  /// Mit [erwartetePruefsumme] wird nur geschrieben, wenn die Datei noch
  /// genau dem zuletzt gelesenen Stand entspricht ('' = Datei fehlt noch).
  /// Sonst wird [DatenWurdenGeaendert] geworfen und nichts geschrieben.
  /// Das ist für Apps gedacht, die ihren Stand im Speicher halten und die
  /// Datei für sich allein nutzen (wie das Kassenbuch).
  Future<DatenStand> aendern(
    FutureOr<void> Function(Map<String, dynamic> daten) aenderung, {
    bool neuAnlegenErlaubt = false,
    Duration warteZeit = const Duration(seconds: 20),
    String? erwartetePruefsumme,
  }) async {
    final sperre = Schreibsperre(
      ordner.schreibsperreDatei,
      app: app,
      benutzer: benutzer,
    );
    await sperre.erwerben(warteZeit: warteZeit);
    try {
      final stand = await lesen();
      if (erwartetePruefsumme != null &&
          (stand?.pruefsumme ?? '') != erwartetePruefsumme) {
        throw DatenWurdenGeaendert(datei.path);
      }
      if (stand == null && !neuAnlegenErlaubt) {
        throw StateError(
          '${datei.path} fehlt im Datenordner ${ordner.wurzel}.',
        );
      }
      final daten = stand?.daten ?? <String, dynamic>{};
      await aenderung(daten);
      final text = _encoder.convert(daten);
      await _sicherSchreiben(text);
      return DatenStand(daten, pruefsummeVon(text));
    } finally {
      await sperre.freigeben();
    }
  }

  /// Erst in eine Hilfsdatei schreiben, dann umbenennen. So liest keine
  /// andere App je eine halb geschriebene Datei.
  Future<void> _sicherSchreiben(String text) async {
    final ziel = datei;
    await ziel.parent.create(recursive: true);
    final hilfsdatei = File(
      '${ziel.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    await hilfsdatei.writeAsString(text, flush: true);
    try {
      await hilfsdatei.rename(ziel.path);
    } on FileSystemException {
      // Manche Netz- oder Cloudlaufwerke erlauben kein Ersetzen per
      // Umbenennen – dann direkt schreiben.
      await ziel.writeAsString(text, flush: true);
      try {
        await hilfsdatei.delete();
      } on FileSystemException {
        // bleibt liegen, schadet nicht
      }
    }
  }
}
