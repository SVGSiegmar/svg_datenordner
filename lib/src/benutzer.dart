import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'cloud_daten.dart';
import 'datenordner.dart';
import 'gemeinsame_daten.dart';
import 'schreibsperre.dart';

/// Gemeinsame Benutzer der Vereins-Apps in `daten/benutzer.json` (ab 0.9.0).
///
/// Festlegung vom 27.11.2026:
/// - Die Apps starten ohne Anmeldung. Die Anmeldung ist freiwillig und lässt
///   sich erst einschalten, wenn mindestens ein Administrator mit E-Mail-Adresse
///   angelegt ist.
/// - Eine Person = ein Konto für alle Apps; die Rechte stehen je App im Konto
///   (`"rechte": {"kassenbuch": [...], "kleingartenverwaltung": [...]}`).
/// - Passwörter nur als PBKDF2-SHA256 mit Salz (100 000 Durchläufe).
/// - Der letzte Administrator kann weder gelöscht, gesperrt noch herabgestuft werden.
/// - Ohne Datenordner liegt dieselbe Datei im Datenbereich der App.
///
/// Aufbau der Datei:
/// ```json
/// {
///   "format": "svg-benutzer", "version": 1,
///   "anmeldungAktiv": false,
///   "benutzer": [
///     {"id": "…", "name": "kassenwart", "email": "kasse@verein.de",
///      "passwort": "pbkdf2-sha256$100000$<Salz>$<Wert>",
///      "rolle": "admin" | "benutzer", "aktiv": true,
///      "rechte": {"kassenbuch": ["buchungen_ansehen"], "kleingartenverwaltung": ["mitglieder.sehen"]}}
///   ]
/// }
/// ```
/// Unbekannte Felder (in der Datei und je Benutzer) bleiben beim Schreiben erhalten.

// ------------------------------------------------------------------ Fehler

class SvgBenutzerFehler implements Exception {
  SvgBenutzerFehler(this.meldung);

  /// Verständlicher Satz für eine Meldung in der App.
  final String meldung;

  @override
  String toString() => 'SvgBenutzerFehler: $meldung';
}

// ---------------------------------------------------------------- Passwort

/// Passwörter sicher speichern und prüfen. Gespeichert wird nur
/// `pbkdf2-sha256$<Durchläufe>$<Salz>$<Prüfwert>` (base64url) – dasselbe Format
/// wie bisher im Kassenbuch. Ältere Einträge (SHA-256 ohne Salz, Kleingartenverwaltung
/// und Kassenbuch bis 2026) werden erkannt und bei der nächsten Anmeldung umgestellt.
class SvgPasswort {
  SvgPasswort._();

  static const String kennung = 'pbkdf2-sha256';
  static const int durchlaeufe = 100000;
  static const int mindestlaenge = 8;

  /// Prüft ein neues Passwort; liefert die Fehlermeldung oder null.
  static String? regelnPruefen(String passwort, [String? wiederholung]) {
    if (passwort.length < mindestlaenge) {
      return 'Das Passwort muss mindestens $mindestlaenge Zeichen haben.';
    }
    if (wiederholung != null && passwort != wiederholung) {
      return 'Passwort und Wiederholung stimmen nicht überein.';
    }
    return null;
  }

  /// Gespeicherten Prüfwert erzeugen (läuft in einem eigenen Isolate, die Oberfläche hängt nicht).
  static Future<String> sichern(String passwort, {int? anzahl}) {
    final n = anzahl ?? durchlaeufe;
    return Isolate.run(() => sichernSync(passwort, anzahl: n));
  }

  /// Passwort gegen den gespeicherten Wert prüfen (neu oder alt).
  static Future<bool> pruefen(String passwort, String gespeichert) =>
      Isolate.run(() => pruefenSync(passwort, gespeichert));

  /// Alter Eintrag ohne Salz?
  static bool veraltet(String gespeichert) => !gespeichert.startsWith('$kennung\$');

  static String sichernSync(String passwort, {int? anzahl}) {
    final n = anzahl ?? durchlaeufe;
    final rnd = Random.secure();
    final salz = List<int>.generate(16, (_) => rnd.nextInt(256));
    final wert = _pbkdf2(utf8.encode(passwort), salz, n);
    return '$kennung\$$n\$${base64Url.encode(salz)}\$${base64Url.encode(wert)}';
  }

  static bool pruefenSync(String passwort, String gespeichert) {
    if (gespeichert.isEmpty) return false;
    if (veraltet(gespeichert)) {
      return _gleich(utf8.encode(sha256.convert(utf8.encode(passwort)).toString()),
          utf8.encode(gespeichert.trim().toLowerCase()));
    }
    final teile = gespeichert.split('\$');
    if (teile.length != 4) return false;
    final n = int.tryParse(teile[1]) ?? 0;
    if (n <= 0) return false;
    try {
      final salz = base64Url.decode(teile[2]);
      final erwartet = base64Url.decode(teile[3]);
      return _gleich(_pbkdf2(utf8.encode(passwort), salz, n), erwartet);
    } on FormatException {
      return false;
    }
  }

  static List<int> _pbkdf2(List<int> passwort, List<int> salz, int n) {
    final hmac = Hmac(sha256, passwort);
    var u = hmac.convert([...salz, 0, 0, 0, 1]).bytes;
    final ergebnis = List<int>.from(u);
    for (var i = 1; i < n; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < ergebnis.length; j++) {
        ergebnis[j] ^= u[j];
      }
    }
    return ergebnis;
  }

  /// Vergleich in gleichbleibender Zeit.
  static bool _gleich(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var unterschied = 0;
    for (var i = 0; i < a.length; i++) {
      unterschied |= a[i] ^ b[i];
    }
    return unterschied == 0;
  }
}

// ------------------------------------------------------------------ Rechte

/// Rechte je App. Die Benutzerverwaltung einer App zeigt und ändert nur die
/// Rechte der eigenen App; die Rechte der anderen Apps bleiben unverändert.
class SvgRechte {
  SvgRechte._();

  static const String kassenbuch = 'kassenbuch';
  static const String kleingartenverwaltung = 'kleingartenverwaltung';

  /// Kassenbuch (Festlegung 27.11.2026, Punkt 6). Benutzerverwaltung: nur Administratoren.
  static const Map<String, String> kassenbuchRechte = {
    'buchungen_ansehen': 'Buchungen ansehen',
    'buchungen_erfassen': 'Buchungen erfassen',
    'buchungen_aendern': 'Buchungen ändern und stornieren',
    'kontoauszug_einlesen': 'Kontoauszug einlesen',
    'forderungen_uebernehmen': 'Forderungen aus der Mitgliederverwaltung übernehmen',
    'zahlungen_zurueckmelden': 'Zahlungen an die Mitgliederverwaltung zurückmelden',
    'jahresabschluss': 'Jahresabschluss',
    'einstellungen': 'Einstellungen',
  };

  /// Kleingartenverwaltung: je Bereich „sehen“ und „ändern“ (`<bereich>.sehen`, `<bereich>.aendern`).
  static const Map<String, String> kleingartenverwaltungBereiche = {
    'mitglieder': 'Mitglieder',
    'ehemaligeMitglieder': 'Ehemalige Mitglieder',
    'pachtflaechen': 'Pachtflächen',
    'allgemeineKosten': 'Allgemeine Kosten',
    'strom': 'Strom',
    'nebenrechnungStrom': 'Nebenrechnung Strom',
    'wasser': 'Wasser',
    'nebenrechnungWasser': 'Nebenrechnung Wasser',
    'anteiligeKosten': 'Anteilige Kosten',
    'versicherung': 'Versicherung',
    'pflichtstunden': 'Pflichtstunden',
    'ordnungsgeld': 'Zusatzkosten',
    'statistik': 'Statistik',
    'forderungen': 'Forderungen',
    'ratenplan': 'Ratenplan',
    'einzelrechnung': 'Jahresrechnung',
    'einstiegsrechnung': 'Einstiegsrechnung',
    'abschlussrechnung': 'Abschlussrechnung',
    'eRechnungen': 'E-Rechnungen',
    'rechnung': 'Rechnung',
    'stammdaten': 'Einstellungen',
    'funktionsverwaltung': 'Funktionen',
    'lizenzInfo': 'Nutzungsbedingungen',
  };

  /// Alle Rechte der Kleingartenverwaltung mit Anzeigetext.
  static Map<String, String> get kleingartenverwaltungRechte => {
        for (final e in kleingartenverwaltungBereiche.entries) ...{
          '${e.key}.sehen': '${e.value} – sehen',
          '${e.key}.aendern': '${e.value} – ändern',
        },
      };

  /// Alle bekannten Rechte einer App (leer für unbekannte Apps).
  static Map<String, String> fuer(String app) {
    switch (app) {
      case kassenbuch:
        return kassenbuchRechte;
      case kleingartenverwaltung:
        return kleingartenverwaltungRechte;
      default:
        return const {};
    }
  }
}

// ----------------------------------------------------------------- Benutzer

class SvgBenutzer {
  SvgBenutzer({
    required this.id,
    required this.name,
    this.email = '',
    this.passwort = '',
    this.rolle = rolleBenutzer,
    this.aktiv = true,
    Map<String, List<String>>? rechte,
    this.angelegtAm,
    this.geaendertAm,
    Map<String, dynamic>? weitere,
  })  : rechte = rechte ?? {},
        weitere = weitere ?? {};

  static const String rolleAdmin = 'admin';
  static const String rolleBenutzer = 'benutzer';

  final String id;
  String name;
  String email;

  /// Gespeicherter Prüfwert (nie das Passwort selbst).
  String passwort;
  String rolle;

  /// false = gesperrt.
  bool aktiv;
  final Map<String, List<String>> rechte;
  DateTime? angelegtAm;
  DateTime? geaendertAm;

  /// Unbekannte Felder (z. B. von neueren Apps) – werden beim Schreiben erhalten.
  final Map<String, dynamic> weitere;

  bool get istAdmin => rolle == rolleAdmin;
  bool get hatEmail => email.trim().contains('@');

  /// Darf dieser Benutzer [recht] in [app]? Administratoren dürfen alles.
  bool darf(String app, String recht) {
    if (!aktiv) return false;
    if (istAdmin) return true;
    final liste = rechte[app] ?? const [];
    return liste.contains('*') || liste.contains(recht);
  }

  /// Passt Name oder E-Mail (ohne Groß-/Kleinschreibung)?
  bool passtZu(String nameOderEmail) {
    final t = nameOderEmail.trim().toLowerCase();
    if (t.isEmpty) return false;
    return name.trim().toLowerCase() == t || (hatEmail && email.trim().toLowerCase() == t);
  }

  static String neueId() {
    final r = Random.secure();
    return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  Map<String, dynamic> toJson() => {
        ...weitere,
        'id': id,
        'name': name,
        'email': email,
        'passwort': passwort,
        'rolle': rolle,
        'aktiv': aktiv,
        'rechte': {for (final e in rechte.entries) e.key: [...e.value]},
        if (angelegtAm != null) 'angelegtAm': angelegtAm!.toIso8601String(),
        if (geaendertAm != null) 'geaendertAm': geaendertAm!.toIso8601String(),
      };

  static const _bekannt = {'id', 'name', 'email', 'passwort', 'rolle', 'aktiv', 'rechte', 'angelegtAm', 'geaendertAm'};

  factory SvgBenutzer.fromJson(Map<String, dynamic> j) {
    final rechte = <String, List<String>>{};
    final roh = j['rechte'];
    if (roh is Map) {
      roh.forEach((app, liste) {
        if (liste is List) rechte[app.toString()] = [for (final r in liste) r.toString()];
      });
    }
    return SvgBenutzer(
      id: (j['id'] ?? '').toString().isEmpty ? neueId() : j['id'].toString(),
      name: (j['name'] ?? '').toString(),
      email: (j['email'] ?? '').toString(),
      passwort: (j['passwort'] ?? '').toString(),
      rolle: j['rolle'] == rolleAdmin ? rolleAdmin : rolleBenutzer,
      aktiv: j['aktiv'] != false,
      rechte: rechte,
      angelegtAm: DateTime.tryParse((j['angelegtAm'] ?? '').toString()),
      geaendertAm: DateTime.tryParse((j['geaendertAm'] ?? '').toString()),
      weitere: {
        for (final e in j.entries)
          if (!_bekannt.contains(e.key)) e.key: e.value,
      },
    );
  }

  /// Übernahme eines Benutzers der bisherigen Kleingartenverwaltung
  /// (`auth` in app_daten.json: name, passwortHash, istAdmin, freigegeben,
  /// rechte {reiter: {sichtbar, schreiben}}). Das Wiederherstellungspasswort entfällt.
  factory SvgBenutzer.ausKleingartenverwaltung(Map<String, dynamic> alt) {
    final liste = <String>[];
    final r = alt['rechte'];
    if (r is Map) {
      r.forEach((reiter, wert) {
        if (wert is Map) {
          if (wert['sichtbar'] == true) liste.add('$reiter.sehen');
          if (wert['schreiben'] == true) liste.add('$reiter.aendern');
        }
      });
    }
    return SvgBenutzer(
      id: (alt['id'] ?? '').toString().isEmpty ? neueId() : 'kgv-${alt['id']}',
      name: (alt['name'] ?? '').toString().trim(),
      passwort: (alt['passwortHash'] ?? '').toString(),
      rolle: alt['istAdmin'] == true ? rolleAdmin : rolleBenutzer,
      aktiv: alt['freigegeben'] == true,
      rechte: {if (liste.isNotEmpty) SvgRechte.kleingartenverwaltung: liste},
      angelegtAm: DateTime.now(),
    );
  }
}

/// Inhalt von `daten/benutzer.json`.
class SvgBenutzerStand {
  SvgBenutzerStand({
    List<SvgBenutzer>? benutzer,
    this.anmeldungAktiv = false,
    Map<String, dynamic>? weitere,
  })  : benutzer = benutzer ?? [],
        weitere = weitere ?? {};

  static const String format = 'svg-benutzer';

  final List<SvgBenutzer> benutzer;
  bool anmeldungAktiv;
  final Map<String, dynamic> weitere;

  List<SvgBenutzer> get aktiveAdmins => benutzer.where((b) => b.istAdmin && b.aktiv).toList();

  /// Die Anmeldung darf eingeschaltet werden, wenn ein aktiver Administrator eine E-Mail-Adresse hat.
  bool get anmeldungMoeglich => aktiveAdmins.any((b) => b.hatEmail);

  SvgBenutzer? suchen(String nameOderEmail) {
    for (final b in benutzer) {
      if (b.passtZu(nameOderEmail)) return b;
    }
    return null;
  }

  SvgBenutzer? nachId(String id) {
    for (final b in benutzer) {
      if (b.id == id) return b;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        ...weitere,
        'format': format,
        'version': 1,
        'anmeldungAktiv': anmeldungAktiv,
        'benutzer': [for (final b in benutzer) b.toJson()],
      };

  factory SvgBenutzerStand.fromJson(Map<String, dynamic> j) {
    final liste = <SvgBenutzer>[];
    final roh = j['benutzer'];
    if (roh is List) {
      for (final e in roh) {
        if (e is Map) liste.add(SvgBenutzer.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return SvgBenutzerStand(
      benutzer: liste,
      anmeldungAktiv: j['anmeldungAktiv'] == true,
      weitere: {
        for (final e in j.entries)
          if (!const {'format', 'version', 'anmeldungAktiv', 'benutzer'}.contains(e.key)) e.key: e.value,
      },
    );
  }

  /// Regeln, die nach jeder Änderung gelten müssen. Wirft [SvgBenutzerFehler].
  void pruefen({SvgBenutzerStand? vorher}) {
    final namen = <String>{};
    final mails = <String>{};
    for (final b in benutzer) {
      final n = b.name.trim().toLowerCase();
      if (n.isEmpty) throw SvgBenutzerFehler('Jeder Benutzer braucht einen Benutzernamen.');
      if (!namen.add(n)) throw SvgBenutzerFehler('Den Benutzernamen „${b.name.trim()}“ gibt es schon.');
      final m = b.email.trim().toLowerCase();
      if (m.isNotEmpty) {
        if (!b.hatEmail) throw SvgBenutzerFehler('„${b.email.trim()}“ ist keine gültige E-Mail-Adresse.');
        if (!mails.add(m)) throw SvgBenutzerFehler('Die E-Mail-Adresse „${b.email.trim()}“ ist schon vergeben.');
      }
    }
    if (vorher != null && vorher.aktiveAdmins.isNotEmpty && aktiveAdmins.isEmpty) {
      throw SvgBenutzerFehler(
          'Der letzte Administrator kann nicht gelöscht, gesperrt oder herabgestuft werden.');
    }
    if (anmeldungAktiv && !anmeldungMoeglich) {
      throw SvgBenutzerFehler(
          'Die Anmeldung lässt sich erst einschalten, wenn mindestens ein Administrator mit E-Mail-Adresse angelegt ist.');
    }
  }
}

// ----------------------------------------------------------------- Speicher

/// Wo `benutzer.json` liegt: Datenordner bzw. Datenbereich der App ([SvgBenutzerDatei])
/// oder SVGCloud ([SvgBenutzerCloud]).
abstract class SvgBenutzerSpeicher {
  /// null, wenn es die Datei noch nicht gibt.
  Future<Map<String, dynamic>?> lesen();

  /// Neu lesen – ändern – schreiben, ohne dass eine andere App dazwischenkommt.
  Future<void> aendern(FutureOr<void> Function(Map<String, dynamic> daten) aenderung);
}

/// `benutzer.json` als Datei, geschrieben unter der gemeinsamen Schreibsperre.
class SvgBenutzerDatei implements SvgBenutzerSpeicher {
  SvgBenutzerDatei(
    this.datei, {
    required this.sperrDatei,
    required this.app,
    this.benutzer = '',
  });

  /// Im gemeinsamen Datenordner: `daten/benutzer.json`, Sperre `locks/schreibsperre.json`.
  factory SvgBenutzerDatei.imOrdner(Datenordner ordner, {required String app, String benutzer = ''}) =>
      SvgBenutzerDatei(ordner.benutzerDatei, sperrDatei: ordner.schreibsperreDatei, app: app, benutzer: benutzer);

  /// Ohne Datenordner: dieselbe Datei im Datenbereich der App.
  factory SvgBenutzerDatei.lokal(Directory datenbereich, {required String app, String benutzer = ''}) =>
      SvgBenutzerDatei(
        File('${datenbereich.path}${Platform.pathSeparator}benutzer.json'),
        sperrDatei: File('${datenbereich.path}${Platform.pathSeparator}locks${Platform.pathSeparator}schreibsperre.json'),
        app: app,
        benutzer: benutzer,
      );

  final File datei;
  final File sperrDatei;
  final String app;

  /// Wird in die Schreibsperre eingetragen (Anmeldename oder „Mein Name auf diesem Gerät“).
  String benutzer;

  static const JsonEncoder _encoder = JsonEncoder.withIndent('  ');

  @override
  Future<Map<String, dynamic>?> lesen() async {
    if (!await datei.exists()) return null;
    final text = await datei.readAsString();
    if (text.trim().isEmpty) return null;
    final roh = jsonDecode(text);
    if (roh is! Map) throw const FormatException('benutzer.json hat kein gültiges Format.');
    return Map<String, dynamic>.from(roh);
  }

  @override
  Future<void> aendern(FutureOr<void> Function(Map<String, dynamic> daten) aenderung) async {
    final sperre = Schreibsperre(sperrDatei, app: app, benutzer: benutzer);
    await sperre.erwerben(warteZeit: const Duration(seconds: 10));
    try {
      final daten = await lesen() ?? <String, dynamic>{};
      await aenderung(daten);
      await _sicherSchreiben(_encoder.convert(daten));
    } finally {
      await sperre.freigeben();
    }
  }

  Future<void> _sicherSchreiben(String text) async {
    await datei.parent.create(recursive: true);
    final hilf = File('${datei.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}');
    await hilf.writeAsString(text, flush: true);
    try {
      await hilf.rename(datei.path);
    } on FileSystemException {
      await datei.writeAsString(text, flush: true);
      try {
        await hilf.delete();
      } on FileSystemException {
        // bleibt liegen, schadet nicht
      }
    }
  }
}

/// `daten/benutzer.json` in der SVGCloud (Versionsprüfung des Servers statt Schreibsperre).
/// Bei einem Konflikt wird einmal neu gelesen und die Änderung erneut ausgeführt.
class SvgBenutzerCloud implements SvgBenutzerSpeicher {
  SvgBenutzerCloud(this.datei);

  final CloudGemeinsameDaten datei;

  @override
  Future<Map<String, dynamic>?> lesen() async => (await datei.lesen())?.daten;

  @override
  Future<void> aendern(FutureOr<void> Function(Map<String, dynamic> daten) aenderung) async {
    for (var versuch = 0;; versuch++) {
      final stand = await datei.lesen();
      try {
        await datei.aendern(aenderung, neuAnlegenErlaubt: true, erwartetePruefsumme: stand?.pruefsumme ?? '');
        return;
      } on DatenWurdenGeaendert {
        if (versuch >= 2) rethrow;
      }
    }
  }
}

// ------------------------------------------------------------ Verwaltung

/// Ergebnis von [SvgBenutzerverwaltung.anmelden].
class SvgAnmeldung {
  SvgAnmeldung(this.benutzer, {this.meldung = ''});
  final SvgBenutzer? benutzer;
  final String meldung;
  bool get erfolgreich => benutzer != null;
}

/// Benutzer lesen, anlegen, ändern, Passwort prüfen und setzen, Rechte abfragen.
/// Die Oberfläche (Liste, Dialoge) bleibt in der App.
class SvgBenutzerverwaltung {
  SvgBenutzerverwaltung(this.speicher, {required this.app});

  final SvgBenutzerSpeicher speicher;

  /// Diese App, z. B. [SvgRechte.kassenbuch].
  final String app;

  /// Durchläufe für neue Passwörter (in Tests kleiner).
  int durchlaeufe = SvgPasswort.durchlaeufe;

  /// Gültigkeit eines Codes für „Passwort vergessen“.
  Duration codeGueltig = const Duration(minutes: 15);
  static const int codeVersuche = 5;

  /// Aktueller Stand (leer, wenn es die Datei noch nicht gibt).
  Future<SvgBenutzerStand> lesen() async {
    final roh = await speicher.lesen();
    return roh == null ? SvgBenutzerStand() : SvgBenutzerStand.fromJson(roh);
  }

  /// Neu lesen – ändern – Regeln prüfen – schreiben. Verstößt die Änderung gegen eine
  /// Regel (letzter Administrator, doppelter Name …), wird nichts geschrieben.
  Future<SvgBenutzerStand> aendern(FutureOr<void> Function(SvgBenutzerStand stand) aenderung) async {
    late SvgBenutzerStand ergebnis;
    await speicher.aendern((daten) async {
      final vorher = SvgBenutzerStand.fromJson(daten);
      final stand = SvgBenutzerStand.fromJson(jsonDecode(jsonEncode(daten)) as Map<String, dynamic>);
      await aenderung(stand);
      stand.pruefen(vorher: vorher);
      daten
        ..clear()
        ..addAll(stand.toJson());
      ergebnis = stand;
    });
    return ergebnis;
  }

  /// Ist die Anmeldung eingeschaltet?
  Future<bool> anmeldungAktiv() async => (await lesen()).anmeldungAktiv;

  /// Anmeldung ein- oder ausschalten (einschalten nur mit Administrator mit E-Mail).
  Future<SvgBenutzerStand> anmeldungSchalten(bool an) => aendern((s) => s.anmeldungAktiv = an);

  /// Neuen Benutzer anlegen. [passwort] darf leer sein (dann vergibt ein Administrator es später).
  Future<SvgBenutzer> anlegen({
    required String name,
    String email = '',
    String passwort = '',
    bool admin = false,
    List<String> rechte = const [],
  }) async {
    if (passwort.isNotEmpty) {
      final fehler = SvgPasswort.regelnPruefen(passwort);
      if (fehler != null) throw SvgBenutzerFehler(fehler);
    }
    final hash = passwort.isEmpty ? '' : await SvgPasswort.sichern(passwort, anzahl: durchlaeufe);
    final neu = SvgBenutzer(
      id: SvgBenutzer.neueId(),
      name: name.trim(),
      email: email.trim(),
      passwort: hash,
      rolle: admin ? SvgBenutzer.rolleAdmin : SvgBenutzer.rolleBenutzer,
      rechte: {if (rechte.isNotEmpty) app: [...rechte]},
      angelegtAm: DateTime.now(),
      geaendertAm: DateTime.now(),
    );
    await aendern((s) => s.benutzer.add(neu));
    return neu;
  }

  /// Benutzer ändern (Name, E-Mail, Rolle, gesperrt, Rechte). Wirft, wenn es ihn nicht mehr gibt.
  Future<SvgBenutzer> benutzerAendern(String id, void Function(SvgBenutzer b) aenderung) async {
    late SvgBenutzer geaendert;
    await aendern((s) {
      final b = s.nachId(id);
      if (b == null) throw SvgBenutzerFehler('Der Benutzer wurde inzwischen gelöscht.');
      aenderung(b);
      b.name = b.name.trim();
      b.email = b.email.trim();
      b.geaendertAm = DateTime.now();
      geaendert = b;
    });
    return geaendert;
  }

  /// Rechte dieser App setzen; die Rechte anderer Apps bleiben unverändert.
  Future<SvgBenutzer> rechteSetzen(String id, List<String> rechte) => benutzerAendern(id, (b) {
        if (rechte.isEmpty) {
          b.rechte.remove(app);
        } else {
          b.rechte[app] = [...rechte];
        }
      });

  Future<void> loeschen(String id) => aendern((s) => s.benutzer.removeWhere((b) => b.id == id));

  /// Passwort setzen (z. B. ein Administrator setzt es zurück).
  Future<void> passwortSetzen(String id, String neuesPasswort) async {
    final fehler = SvgPasswort.regelnPruefen(neuesPasswort);
    if (fehler != null) throw SvgBenutzerFehler(fehler);
    final hash = await SvgPasswort.sichern(neuesPasswort, anzahl: durchlaeufe);
    await benutzerAendern(id, (b) {
      b.passwort = hash;
      b.weitere.remove('ruecksetzung');
    });
  }

  /// Anmelden mit Benutzername oder E-Mail. Alte Prüfwerte ohne Salz werden dabei umgestellt.
  Future<SvgAnmeldung> anmelden(String nameOderEmail, String passwort) async {
    final b = (await lesen()).suchen(nameOderEmail);
    const falsch = 'Benutzername/E-Mail oder Passwort ist falsch.';
    if (b == null || b.passwort.isEmpty) return SvgAnmeldung(null, meldung: falsch);
    if (!await SvgPasswort.pruefen(passwort, b.passwort)) return SvgAnmeldung(null, meldung: falsch);
    if (!b.aktiv) return SvgAnmeldung(null, meldung: 'Dieser Zugang ist gesperrt. Bitte an einen Administrator wenden.');
    if (SvgPasswort.veraltet(b.passwort)) {
      try {
        final hash = await SvgPasswort.sichern(passwort, anzahl: durchlaeufe);
        await benutzerAendern(b.id, (x) => x.passwort = hash);
        b.passwort = hash;
      } catch (_) {
        // Umstellen ist nicht wichtig genug, um die Anmeldung scheitern zu lassen
      }
    }
    return SvgAnmeldung(b);
  }

  /// „Passwort vergessen“: sechsstelligen Code erzeugen und (nur als Prüfwert) beim Benutzer
  /// ablegen. Die App verschickt den Code über den Postausgang des Vereins an [SvgBenutzer.email].
  /// Liefert (Benutzer, Code) oder null, wenn es keinen aktiven Benutzer mit dieser E-Mail-Adresse gibt.
  Future<({SvgBenutzer benutzer, String code})?> codeErzeugen(String nameOderEmail) async {
    final b = (await lesen()).suchen(nameOderEmail);
    if (b == null || !b.aktiv || !b.hatEmail) return null;
    final code = (Random.secure().nextInt(900000) + 100000).toString();
    final hash = await SvgPasswort.sichern(code, anzahl: 20000);
    final bis = DateTime.now().add(codeGueltig);
    final geaendert = await benutzerAendern(b.id, (x) {
      x.weitere['ruecksetzung'] = {'code': hash, 'bis': bis.toIso8601String(), 'versuche': 0};
    });
    return (benutzer: geaendert, code: code);
  }

  /// Code prüfen und neues Passwort setzen. Wirft [SvgBenutzerFehler] mit dem Grund.
  Future<void> mitCodeZuruecksetzen(String nameOderEmail, String code, String neuesPasswort) async {
    final fehler = SvgPasswort.regelnPruefen(neuesPasswort);
    if (fehler != null) throw SvgBenutzerFehler(fehler);
    final b = (await lesen()).suchen(nameOderEmail);
    final r = b?.weitere['ruecksetzung'];
    if (b == null || r is! Map) throw SvgBenutzerFehler('Es wurde kein Code angefordert.');
    final bis = DateTime.tryParse((r['bis'] ?? '').toString());
    final versuche = (r['versuche'] as num?)?.toInt() ?? 0;
    if (bis == null || DateTime.now().isAfter(bis)) {
      await benutzerAendern(b.id, (x) => x.weitere.remove('ruecksetzung'));
      throw SvgBenutzerFehler('Der Code ist abgelaufen. Bitte einen neuen anfordern.');
    }
    if (versuche >= codeVersuche) {
      throw SvgBenutzerFehler('Zu viele falsche Versuche. Bitte einen neuen Code anfordern.');
    }
    if (!await SvgPasswort.pruefen(code.trim(), (r['code'] ?? '').toString())) {
      await benutzerAendern(b.id, (x) {
        final akt = x.weitere['ruecksetzung'];
        if (akt is Map) x.weitere['ruecksetzung'] = {...akt, 'versuche': versuche + 1};
      });
      throw SvgBenutzerFehler('Der Code stimmt nicht.');
    }
    await passwortSetzen(b.id, neuesPasswort);
  }

  /// Bisherige Benutzer der Kleingartenverwaltung übernehmen, wenn `benutzer.json` noch
  /// keine Benutzer enthält. Vorhandene Konten werden nie überschrieben. Liefert die Anzahl.
  Future<int> ausKleingartenverwaltungUebernehmen(List<Map<String, dynamic>> alt) async {
    var anzahl = 0;
    await aendern((s) {
      if (s.benutzer.isNotEmpty) return;
      for (final a in alt) {
        final b = SvgBenutzer.ausKleingartenverwaltung(a);
        if (b.name.isEmpty || s.suchen(b.name) != null) continue;
        s.benutzer.add(b);
        anzahl++;
      }
    });
    return anzahl;
  }

  /// Darf [benutzer] [recht] in dieser App? Ist die Anmeldung ausgeschaltet, darf jeder alles.
  bool darf(SvgBenutzer? benutzer, String recht, {required bool anmeldungAktiv}) {
    if (!anmeldungAktiv) return true;
    return benutzer?.darf(app, recht) ?? false;
  }
}
