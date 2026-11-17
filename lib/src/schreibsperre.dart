import 'dart:convert';
import 'dart:io';

/// Wird geworfen, wenn eine andere App die Datei gerade schreibt und die
/// Wartezeit abgelaufen ist.
class SchreibsperreBelegt implements Exception {
  SchreibsperreBelegt(this.inhaber);

  /// Inhalt der Sperrdatei (app, rechner, benutzer, zeit) – kann null sein.
  final Map<String, dynamic>? inhaber;

  String get beschreibung {
    final i = inhaber;
    if (i == null) return 'Eine andere App speichert gerade.';
    final app = (i['app'] ?? '?').toString();
    final rechner = (i['rechner'] ?? '?').toString();
    final benutzer = (i['benutzer'] ?? '').toString();
    final wer = benutzer.isEmpty ? rechner : '$benutzer an $rechner';
    return '$app ($wer) speichert gerade.';
  }

  @override
  String toString() => 'SchreibsperreBelegt: $beschreibung';
}

/// Kurze Sperre nur für den Moment des Speicherns.
///
/// Funktionsweise: Die Sperrdatei wird „exklusiv“ angelegt – das gelingt
/// immer nur einer App. Wer sie nicht anlegen kann, wartet kurz und versucht
/// es erneut. Stürzt eine App beim Speichern ab, gilt die Sperre nach
/// [verwaistNach] als verwaist und wird übernommen.
///
/// Gedacht für NAS und Speicher an der FRITZ!Box. Bei Sync-Ordnern
/// (OneDrive, iCloud, MagentaCloud) kommt die Sperre wegen der
/// Synchronisationsverzögerung beim anderen Rechner evtl. zu spät an.
class Schreibsperre {
  Schreibsperre(
    this.datei, {
    required this.app,
    String? rechner,
    this.benutzer = '',
    this.verwaistNach = const Duration(minutes: 2),
    DateTime Function()? uhr,
  })  : rechner = rechner ?? _rechnername(),
        _uhr = uhr ?? DateTime.now {
    id = '$app-${this.rechner}-$pid-${DateTime.now().microsecondsSinceEpoch}';
  }

  final File datei;
  final String app;
  final String rechner;
  final String benutzer;

  /// Großzügig gewählt, weil die Uhren der Rechner abweichen können.
  /// Ein Speichervorgang dauert nur Sekunden.
  final Duration verwaistNach;

  final DateTime Function() _uhr;
  late final String id;
  bool _gehalten = false;

  bool get gehalten => _gehalten;

  /// Ein Versuch, ohne zu warten.
  Future<bool> versuchen() async {
    if (_gehalten) return true;
    await datei.parent.create(recursive: true);
    if (!await _exklusivAnlegen()) {
      final verwaisteId = await _verwaisteId();
      if (verwaisteId == null) return false;
      // Nur löschen, wenn es noch dieselbe verwaiste Sperre ist.
      final aktuell = await inhaber();
      if ((aktuell?['id'] ?? '') != verwaisteId) return false;
      try {
        await datei.delete();
      } on FileSystemException {
        // schon weg – egal
      }
      if (!await _exklusivAnlegen()) return false;
    }
    await datei.writeAsString(jsonEncode(_eintrag()), flush: true);
    _gehalten = true;
    return true;
  }

  /// Wartet höchstens [warteZeit] auf die Sperre.
  Future<void> erwerben({
    Duration warteZeit = const Duration(seconds: 20),
    Duration intervall = const Duration(milliseconds: 400),
  }) async {
    final ende = DateTime.now().add(warteZeit);
    while (true) {
      if (await versuchen()) return;
      if (DateTime.now().isAfter(ende)) {
        throw SchreibsperreBelegt(await inhaber());
      }
      await Future<void>.delayed(intervall);
    }
  }

  /// Gibt die Sperre frei – aber nur die eigene.
  Future<void> freigeben() async {
    if (!_gehalten) return;
    _gehalten = false;
    try {
      final aktuell = await inhaber();
      if (aktuell == null || aktuell['id'] == id) {
        await datei.delete();
      }
    } on FileSystemException {
      // Datei schon entfernt
    }
  }

  /// Inhalt der Sperrdatei, oder null wenn keine (lesbare) Sperre besteht.
  Future<Map<String, dynamic>?> inhaber() async {
    try {
      final text = await datei.readAsString();
      final roh = jsonDecode(text);
      return roh is Map ? Map<String, dynamic>.from(roh) : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic> _eintrag() => {
        'id': id,
        'app': app,
        'rechner': rechner,
        'benutzer': benutzer,
        'zeit': _uhr().toIso8601String(),
      };

  Future<bool> _exklusivAnlegen() async {
    try {
      await datei.create(exclusive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Liefert die ID einer verwaisten Sperre ('' wenn ohne ID), sonst null.
  Future<String?> _verwaisteId() async {
    final aktuell = await inhaber();
    DateTime? zeit = DateTime.tryParse((aktuell?['zeit'] ?? '').toString());
    if (zeit == null) {
      // Gerade angelegt, aber noch leer – oder unlesbar: Dateizeit nehmen.
      try {
        zeit = (await datei.stat()).modified;
      } on FileSystemException {
        return '';
      }
    }
    if (_uhr().difference(zeit) < verwaistNach) return null;
    return (aktuell?['id'] ?? '').toString();
  }

  static String _rechnername() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'unbekannt';
    }
  }
}
