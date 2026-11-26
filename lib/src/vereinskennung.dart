import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'datenordner.dart';

/// Kennung eines Vereins im gemeinsamen Datenordner: `daten/verein.json`.
///
/// Wird einmal angelegt, wenn ein Verein einen Ordner zum ersten Mal nutzt,
/// und danach nie überschrieben. Jede App prüft beim Auswählen eines Ordners
/// mit [VereinsPruefung.pruefen], ob der Ordner zum eigenen Verein gehört,
/// bevor sie Daten lädt, zusammenführt oder schreibt.
class Vereinskennung {
  Vereinskennung({
    required this.name,
    required this.kennung,
    required this.angelegtAm,
    this.angelegtVon = '',
  });

  /// Vereinsname, wie er beim Anlegen eingetragen war.
  final String name;

  /// Zufällige, feste Kennung (16 Hex-Zeichen).
  final String kennung;

  final DateTime angelegtAm;

  /// App, die die Kennung angelegt hat.
  final String angelegtVon;

  static const String format = 'svg-vereinskennung';

  Map<String, dynamic> toJson() => {
        'format': format,
        'version': 1,
        'name': name,
        'kennung': kennung,
        'angelegtAm': angelegtAm.toIso8601String(),
        'angelegtVon': angelegtVon,
      };

  static Vereinskennung? fromJson(Object? roh) {
    if (roh is! Map) return null;
    final kennung = (roh['kennung'] ?? '').toString().trim();
    if (kennung.isEmpty) return null;
    return Vereinskennung(
      name: (roh['name'] ?? '').toString().trim(),
      kennung: kennung,
      angelegtAm:
          DateTime.tryParse((roh['angelegtAm'] ?? '').toString()) ?? DateTime(2000),
      angelegtVon: (roh['angelegtVon'] ?? '').toString(),
    );
  }

  static String neueKennung() {
    final r = Random.secure();
    return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

/// Ergebnis von [VereinsPruefung.pruefen].
enum VereinsStatus {
  /// Im Ordner liegen noch keine Datendateien: frei für diesen Verein.
  ordnerLeer,

  /// Kennung oder Vereinsname passen.
  gleicherVerein,

  /// Kennung oder Vereinsname weichen ab: nichts laden, nichts schreiben.
  andererVerein,

  /// Es liegen Daten im Ordner, aber kein Vereinsname ist erkennbar:
  /// den Benutzer fragen.
  unklar,
}

class VereinsErgebnis {
  VereinsErgebnis(this.status, {this.imOrdner, this.nameImOrdner = ''});

  final VereinsStatus status;

  /// Kennung aus `daten/verein.json`, falls vorhanden.
  final Vereinskennung? imOrdner;

  /// Vereinsname, der im Ordner gefunden wurde (Kennung oder app_daten.json).
  final String nameImOrdner;

  bool get darfWeiter =>
      status == VereinsStatus.ordnerLeer || status == VereinsStatus.gleicherVerein;

  /// Satz für eine Meldung an den Benutzer.
  String get text {
    switch (status) {
      case VereinsStatus.ordnerLeer:
        return 'Der Ordner enthält noch keine Vereinsdaten.';
      case VereinsStatus.gleicherVerein:
        return 'Der Ordner gehört zu „$nameImOrdner“.';
      case VereinsStatus.andererVerein:
        return 'Dieser Ordner gehört zu einem anderen Verein'
            '${nameImOrdner.isEmpty ? '' : ' („$nameImOrdner“)'}. '
            'Es wurde nichts geladen und nichts geschrieben. '
            'Bitte den Ordner des eigenen Vereins wählen.';
      case VereinsStatus.unklar:
        return 'Im Ordner liegen bereits Daten, ein Vereinsname ist aber nicht '
            'erkennbar. Bitte prüfen, ob es der Ordner des eigenen Vereins ist.';
    }
  }
}

class VereinsPruefung {
  VereinsPruefung._();

  /// Liest `daten/verein.json`. null, wenn sie fehlt oder unlesbar ist.
  static Future<Vereinskennung?> lesen(Datenordner ordner) async {
    final datei = ordner.vereinDatei;
    if (!await datei.exists()) return null;
    try {
      return Vereinskennung.fromJson(jsonDecode(await datei.readAsString()));
    } catch (_) {
      return null;
    }
  }

  /// Legt die Kennung an, falls noch keine da ist. Eine vorhandene wird nie
  /// überschrieben, sondern zurückgegeben.
  static Future<Vereinskennung> anlegen(
    Datenordner ordner, {
    required String vereinsname,
    String app = '',
  }) async {
    final vorhanden = await lesen(ordner);
    if (vorhanden != null) return vorhanden;
    final neu = Vereinskennung(
      name: vereinsname.trim(),
      kennung: Vereinskennung.neueKennung(),
      angelegtAm: DateTime.now(),
      angelegtVon: app,
    );
    final datei = ordner.vereinDatei;
    await datei.parent.create(recursive: true);
    if (await datei.exists()) return (await lesen(ordner)) ?? neu;
    final hilf = File('${datei.path}.tmp-$pid');
    await hilf.writeAsString(
        const JsonEncoder.withIndent('  ').convert(neu.toJson()),
        flush: true);
    await hilf.rename(datei.path);
    return neu;
  }

  /// Prüft, ob [ordner] zum eigenen Verein gehört.
  ///
  /// [eigeneKennung]: die Kennung, die sich die App für ihren Verein gemerkt
  /// hat (falls schon einmal ein Ordner geprüft wurde). Sie geht vor dem Namen.
  static Future<VereinsErgebnis> pruefen(
    Datenordner ordner, {
    required String eigenerVereinsname,
    String eigeneKennung = '',
  }) async {
    final kennung = await lesen(ordner);
    if (kennung != null) {
      final gleich = eigeneKennung.trim().isNotEmpty
          ? eigeneKennung.trim() == kennung.kennung
          : gleicherName(eigenerVereinsname, kennung.name);
      return VereinsErgebnis(
        gleich ? VereinsStatus.gleicherVerein : VereinsStatus.andererVerein,
        imOrdner: kennung,
        nameImOrdner: kennung.name,
      );
    }
    if (!await _hatDaten(ordner)) {
      return VereinsErgebnis(VereinsStatus.ordnerLeer);
    }
    final name = await _nameAusVerwaltung(ordner);
    if (name.isEmpty || eigenerVereinsname.trim().isEmpty) {
      return VereinsErgebnis(VereinsStatus.unklar, nameImOrdner: name);
    }
    return VereinsErgebnis(
      gleicherName(eigenerVereinsname, name)
          ? VereinsStatus.gleicherVerein
          : VereinsStatus.andererVerein,
      nameImOrdner: name,
    );
  }

  /// Vergleicht zwei Vereinsnamen ohne Groß-/Kleinschreibung, Satzzeichen,
  /// Leerzeichen und den Zusatz „e. V.“.
  static bool gleicherName(String a, String b) {
    final x = namensSchluessel(a), y = namensSchluessel(b);
    return x.isNotEmpty && x == y;
  }

  static String namensSchluessel(String name) {
    var s = name.toLowerCase().replaceAll('ß', 'ss');
    s = s.replaceAll(RegExp(r'\be\.?\s*v\.?\s*$'), '');
    return s.replaceAll(RegExp(r'[^a-z0-9äöü]'), '');
  }

  static Future<bool> _hatDaten(Datenordner ordner) async {
    for (final f in [
      ordner.datenDatei,
      ordner.kassenbuchDatei,
      ordner.gartenvergabeDatei,
    ]) {
      if (await f.exists()) return true;
    }
    return false;
  }

  static Future<String> _nameAusVerwaltung(Datenordner ordner) async {
    try {
      final f = ordner.datenDatei;
      if (!await f.exists()) return '';
      final d = jsonDecode(await f.readAsString());
      if (d is Map && d['stammdaten'] is Map) {
        return ((d['stammdaten'] as Map)['vereinsname'] ?? '').toString().trim();
      }
    } catch (_) {}
    return '';
  }
}
