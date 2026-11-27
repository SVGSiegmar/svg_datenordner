import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:mailer/mailer.dart' as mail;
import 'package:mailer/smtp_server.dart' as mail;

import 'datenordner.dart';
import 'gemeinsame_daten.dart';

// Gemeinsame Benutzerverwaltung (0.9.0, Entscheidung 27.11.2026) für
// Kassenbuch und Mitgliederverwaltung.
//
// - Datei `daten/benutzer.json` im Datenordner (ohne Datenordner: dieselbe
//   Datei im Datenbereich der App). Eine Person = ein Konto für alle Apps.
// - Passwörter nur als PBKDF2-SHA256 mit Salz
//   (`pbkdf2-sha256$<Durchläufe>$<Salz>$<Prüfwert>`), kompatibel zum
//   bisherigen Kassenbuch.
// - Rechte je App: `"rechte": {"kassenbuch": [...], "kleingartenverwaltung": [...]}`.
//   Administratoren dürfen alles.
// - Gelesen und geschrieben wird immer unter der Schreibsperre
//   (neu lesen – Änderung einfügen – schreiben, siehe [GemeinsameDaten]).
// - Die Anmeldung lässt sich erst einschalten, wenn mindestens ein aktiver
//   Administrator mit E-Mail-Adresse angelegt ist. Der letzte Administrator
//   kann nicht gelöscht, deaktiviert oder herabgestuft werden.

/// Fehler mit einem Satz für die Meldung an den Benutzer.
class BenutzerFehler implements Exception {
  BenutzerFehler(this.meldung);
  final String meldung;
  @override
  String toString() => 'BenutzerFehler: $meldung';
}

/// Ein Konto (für alle Apps des Vereins).
class SvgBenutzer {
  SvgBenutzer({
    required this.id,
    this.benutzername = '',
    this.email = '',
    this.passwort = '',
    this.admin = false,
    this.aktiv = true,
    Map<String, List<String>>? rechte,
    this.angelegtAm = '',
    this.geaendertAm = '',
    this.letzteAnmeldung = '',
    Map<String, dynamic>? weitere,
  })  : rechte = rechte ?? {},
        weitere = weitere ?? {};

  final String id;
  String benutzername;
  String email;

  /// Gespeicherter Prüfwert (nie das Passwort).
  String passwort;
  bool admin;
  bool aktiv;

  /// Rechte je App, z. B. `{"kassenbuch": ["buchungen_ansehen"]}`.
  Map<String, List<String>> rechte;
  String angelegtAm;
  String geaendertAm;
  String letzteAnmeldung;

  /// Felder, die diese Version nicht kennt – bleiben beim Schreiben erhalten.
  final Map<String, dynamic> weitere;

  /// Für Anzeigen und den Änderungsverlauf.
  String get anzeigename => benutzername.trim().isNotEmpty ? benutzername.trim() : email.trim();

  bool get hatEmail => email.contains('@');

  /// Darf dieser Benutzer [recht] in [app]? Administratoren dürfen alles,
  /// deaktivierte Konten nichts.
  bool darf(String app, String recht) =>
      aktiv && (admin || (rechte[app]?.contains(recht) ?? false));

  List<String> rechteFuer(String app) => List.unmodifiable(rechte[app] ?? const []);

  Map<String, dynamic> toJson() => {
        ...weitere,
        'id': id,
        'benutzername': benutzername,
        'email': email,
        'passwort': passwort,
        'admin': admin,
        'aktiv': aktiv,
        'rechte': {for (final e in rechte.entries) e.key: [...e.value]},
        'angelegtAm': angelegtAm,
        'geaendertAm': geaendertAm,
        'letzteAnmeldung': letzteAnmeldung,
      };

  static const _bekannt = {
    'id', 'benutzername', 'email', 'passwort', 'admin', 'aktiv', 'rechte',
    'angelegtAm', 'geaendertAm', 'letzteAnmeldung',
  };

  factory SvgBenutzer.fromJson(Map<String, dynamic> j) {
    final rechte = <String, List<String>>{};
    final r = j['rechte'];
    if (r is Map) {
      for (final e in r.entries) {
        if (e.value is List) {
          rechte[e.key.toString()] = [for (final x in e.value as List) x.toString()];
        }
      }
    }
    return SvgBenutzer(
      id: (j['id'] ?? '').toString(),
      benutzername: (j['benutzername'] ?? '').toString(),
      email: (j['email'] ?? '').toString(),
      passwort: (j['passwort'] ?? '').toString(),
      admin: j['admin'] == true,
      aktiv: j['aktiv'] != false,
      rechte: rechte,
      angelegtAm: (j['angelegtAm'] ?? '').toString(),
      geaendertAm: (j['geaendertAm'] ?? '').toString(),
      letzteAnmeldung: (j['letzteAnmeldung'] ?? '').toString(),
      weitere: {
        for (final e in j.entries)
          if (!_bekannt.contains(e.key)) e.key: e.value
      },
    );
  }
}

/// Postausgang des Vereins für den Code „Passwort vergessen“. Das Passwort
/// für den Postausgang steht NICHT hier, sondern im sicheren Speicher des
/// jeweiligen Geräts.
class Postausgang {
  Postausgang({
    required this.server,
    this.port = 587,
    this.verschluesselung = 'starttls',
    this.benutzername = '',
    required this.absenderAdresse,
    this.absenderName = '',
  });

  String server;
  int port;

  /// 'starttls' (meist Port 587), 'ssl' (meist Port 465) oder 'keine'.
  String verschluesselung;
  String benutzername;
  String absenderAdresse;
  String absenderName;

  bool get vollstaendig => server.trim().isNotEmpty && absenderAdresse.contains('@');

  Map<String, dynamic> toJson() => {
        'server': server,
        'port': port,
        'verschluesselung': verschluesselung,
        'benutzername': benutzername,
        'absenderAdresse': absenderAdresse,
        'absenderName': absenderName,
      };

  static Postausgang? fromJson(Object? roh) {
    if (roh is! Map) return null;
    return Postausgang(
      server: (roh['server'] ?? '').toString(),
      port: int.tryParse((roh['port'] ?? '').toString()) ?? 587,
      verschluesselung: (roh['verschluesselung'] ?? 'starttls').toString(),
      benutzername: (roh['benutzername'] ?? '').toString(),
      absenderAdresse: (roh['absenderAdresse'] ?? '').toString(),
      absenderName: (roh['absenderName'] ?? '').toString(),
    );
  }
}

/// Inhalt von daten/benutzer.json.
class Benutzerliste {
  Benutzerliste({
    this.anmeldungAn = false,
    List<SvgBenutzer>? benutzer,
    this.postausgang,
    List<Map<String, dynamic>>? codes,
    Map<String, dynamic>? weitere,
    this.dateiVorhanden = false,
  })  : benutzer = benutzer ?? [],
        codes = codes ?? [],
        weitere = weitere ?? {};

  static const format = 'svg-benutzer';

  /// Anmeldung beim Start eingeschaltet.
  bool anmeldungAn;
  final List<SvgBenutzer> benutzer;
  Postausgang? postausgang;

  /// Offene Codes „Passwort vergessen“ (nur Prüfwerte).
  final List<Map<String, dynamic>> codes;
  final Map<String, dynamic> weitere;

  /// Gab es die Datei schon (false = noch nie angelegt)?
  final bool dateiVorhanden;

  /// Gilt die Anmeldung? (eingeschaltet und ein aktiver Administrator da)
  bool get anmeldungAktiv => anmeldungAn && benutzer.any((b) => b.aktiv && b.admin);

  /// Lässt sich die Anmeldung einschalten?
  bool get anmeldungMoeglich => benutzer.any((b) => b.aktiv && b.admin && b.hatEmail);

  Iterable<SvgBenutzer> get aktiveAdmins => benutzer.where((b) => b.aktiv && b.admin);

  SvgBenutzer? nachId(String id) => benutzer.where((b) => b.id == id).firstOrNull;

  /// Sucht nach Benutzername oder E-Mail (Groß-/Kleinschreibung egal).
  SvgBenutzer? finden(String nameOderEmail) {
    final s = nameOderEmail.trim().toLowerCase();
    if (s.isEmpty) return null;
    return benutzer
            .where((b) => b.benutzername.trim().toLowerCase() == s)
            .firstOrNull ??
        benutzer.where((b) => b.email.trim().toLowerCase() == s).firstOrNull;
  }

  Map<String, dynamic> toJson() => {
        ...weitere,
        'format': format,
        'version': 1,
        'anmeldungAn': anmeldungAn,
        'benutzer': [for (final b in benutzer) b.toJson()],
        if (postausgang != null) 'postausgang': postausgang!.toJson(),
        'codes': codes,
      };

  factory Benutzerliste.fromJson(Map<String, dynamic> j, {bool dateiVorhanden = true}) {
    final roh = j['benutzer'];
    final c = j['codes'];
    return Benutzerliste(
      anmeldungAn: j['anmeldungAn'] == true,
      benutzer: [
        if (roh is List)
          for (final b in roh)
            if (b is Map) SvgBenutzer.fromJson(Map<String, dynamic>.from(b))
      ],
      postausgang: Postausgang.fromJson(j['postausgang']),
      codes: [
        if (c is List)
          for (final x in c)
            if (x is Map) Map<String, dynamic>.from(x)
      ],
      weitere: {
        for (final e in j.entries)
          if (!const {'format', 'version', 'anmeldungAn', 'benutzer', 'postausgang', 'codes'}
              .contains(e.key))
            e.key: e.value
      },
      dateiVorhanden: dateiVorhanden,
    );
  }
}

/// Versand einer E-Mail; in Tests austauschbar.
typedef MailVersand = Future<void> Function(
    Postausgang postausgang, String smtpPasswort, String an, String betreff, String text);

/// Lesen und Ändern der gemeinsamen Benutzerdatei.
class Benutzerverwaltung {
  Benutzerverwaltung(
    this.ordner, {
    required this.app,
    this.benutzer = '',
    File? datei,
    DateTime Function()? uhr,
  })  : datei = datei ?? ordner.benutzerDatei,
        _uhr = uhr ?? DateTime.now;

  /// Schlüssel der Apps in „rechte“.
  static const appKassenbuch = 'kassenbuch';
  static const appKleingartenverwaltung = 'kleingartenverwaltung';

  static const passwortMindestlaenge = 8;
  static const codeGueltigkeit = Duration(minutes: 15);
  static const codeVersuche = 5;

  final Datenordner ordner;

  /// Anzeigename der App für Sperre und Protokoll (z. B. „Kassenbuch“).
  final String app;

  /// Wer gerade ändert (für die Schreibsperre).
  final String benutzer;
  final File datei;
  final DateTime Function() _uhr;

  GemeinsameDaten get _daten =>
      GemeinsameDaten(ordner, app: app, benutzer: benutzer, datei: datei);

  String get _jetzt => _uhr().toIso8601String();

  /// Liest die Benutzerliste. Fehlt die Datei, kommt eine leere Liste
  /// (Anmeldung aus).
  Future<Benutzerliste> lesen() async {
    final stand = await _daten.lesen();
    if (stand == null) return Benutzerliste();
    return Benutzerliste.fromJson(stand.daten);
  }

  /// Ändert die Liste unter der Schreibsperre (neu lesen – ändern –
  /// schreiben). Prüft danach die Regeln (letzter Administrator, Anmeldung).
  Future<Benutzerliste> aendern(FutureOr<void> Function(Benutzerliste liste) aenderung) async {
    late Benutzerliste ergebnis;
    await _daten.aendern((d) async {
      final vorher = Benutzerliste.fromJson(d, dateiVorhanden: d.isNotEmpty);
      final hatteAdmin = vorher.aktiveAdmins.isNotEmpty;
      await aenderung(vorher);
      if (hatteAdmin && vorher.aktiveAdmins.isEmpty) {
        throw BenutzerFehler(
            'Der letzte Administrator kann nicht gelöscht, deaktiviert oder herabgestuft werden.');
      }
      if (vorher.anmeldungAn && !vorher.anmeldungMoeglich) {
        throw BenutzerFehler(
            'Solange die Anmeldung eingeschaltet ist, muss mindestens ein aktiver Administrator eine E-Mail-Adresse haben.');
      }
      d
        ..clear()
        ..addAll(vorher.toJson());
      ergebnis = vorher;
    }, neuAnlegenErlaubt: true);
    return Benutzerliste.fromJson(ergebnis.toJson());
  }

  static void _eindeutig(Benutzerliste l, String name, String email, {String? ausser}) {
    for (final b in l.benutzer) {
      if (b.id == ausser) continue;
      for (final wert in [name, email]) {
        final w = wert.trim().toLowerCase();
        if (w.isEmpty) continue;
        if (b.benutzername.trim().toLowerCase() == w || b.email.trim().toLowerCase() == w) {
          throw BenutzerFehler('„${wert.trim()}“ ist schon vergeben.');
        }
      }
    }
  }

  static String? passwortRegelnPruefen(String passwort, [String? wiederholung]) {
    if (passwort.length < passwortMindestlaenge) {
      return 'Das Passwort muss mindestens $passwortMindestlaenge Zeichen haben.';
    }
    if (wiederholung != null && passwort != wiederholung) {
      return 'Passwort und Wiederholung stimmen nicht überein.';
    }
    return null;
  }

  static void _emailPruefen(String email) {
    final e = email.trim();
    if (e.isNotEmpty && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e)) {
      throw BenutzerFehler('Die E-Mail-Adresse „$e“ sieht nicht gültig aus.');
    }
  }

  /// Neues Konto. Das erste Konto wird immer Administrator.
  Future<SvgBenutzer> anlegen({
    String benutzername = '',
    String email = '',
    required String passwort,
    bool admin = false,
    Map<String, List<String>>? rechte,
  }) async {
    if (benutzername.trim().isEmpty && email.trim().isEmpty) {
      throw BenutzerFehler('Bitte einen Benutzernamen oder eine E-Mail-Adresse eingeben.');
    }
    _emailPruefen(email);
    final regel = passwortRegelnPruefen(passwort);
    if (regel != null) throw BenutzerFehler(regel);
    final pruefwert = await passwortSichern(passwort);
    late SvgBenutzer neu;
    await aendern((l) {
      _eindeutig(l, benutzername, email);
      neu = SvgBenutzer(
        id: _neueId(),
        benutzername: benutzername.trim(),
        email: email.trim(),
        passwort: pruefwert,
        admin: admin || l.benutzer.isEmpty,
        rechte: rechte,
        angelegtAm: _jetzt,
        geaendertAm: _jetzt,
      );
      l.benutzer.add(neu);
    });
    return neu;
  }

  /// Konto ändern. Nur angegebene Felder werden geändert; [rechte] ersetzt
  /// nur die Rechte der genannten Apps, die anderer Apps bleiben.
  Future<SvgBenutzer> bearbeiten(
    String id, {
    String? benutzername,
    String? email,
    bool? admin,
    bool? aktiv,
    Map<String, List<String>>? rechte,
  }) async {
    if (email != null) _emailPruefen(email);
    late SvgBenutzer b;
    await aendern((l) {
      final x = l.nachId(id);
      if (x == null) throw BenutzerFehler('Das Konto gibt es nicht mehr.');
      final name = benutzername ?? x.benutzername;
      final mail = email ?? x.email;
      if (name.trim().isEmpty && mail.trim().isEmpty) {
        throw BenutzerFehler('Bitte einen Benutzernamen oder eine E-Mail-Adresse eingeben.');
      }
      _eindeutig(l, name, mail, ausser: id);
      x
        ..benutzername = name.trim()
        ..email = mail.trim()
        ..admin = admin ?? x.admin
        ..aktiv = aktiv ?? x.aktiv
        ..geaendertAm = _jetzt;
      if (rechte != null) {
        for (final e in rechte.entries) {
          x.rechte[e.key] = [...e.value];
        }
      }
      b = x;
    });
    return b;
  }

  Future<void> loeschen(String id) async {
    await aendern((l) {
      final x = l.nachId(id);
      if (x == null) return;
      l.benutzer.remove(x);
      l.codes.removeWhere((c) => c['benutzer'] == id);
    });
  }

  /// Passwort setzen (Administrator setzt zurück oder eigene Änderung).
  Future<void> passwortSetzen(String id, String neu) async {
    final regel = passwortRegelnPruefen(neu);
    if (regel != null) throw BenutzerFehler(regel);
    final pruefwert = await passwortSichern(neu);
    await aendern((l) {
      final x = l.nachId(id);
      if (x == null) throw BenutzerFehler('Das Konto gibt es nicht mehr.');
      x
        ..passwort = pruefwert
        ..geaendertAm = _jetzt;
      l.codes.removeWhere((c) => c['benutzer'] == id);
    });
  }

  /// Prüft Name/E-Mail und Passwort. Liefert das Konto oder null.
  /// Vermerkt die Anmeldung und stellt alte Prüfwerte sicher um.
  Future<SvgBenutzer?> anmelden(String nameOderEmail, String passwort) async {
    final l = await lesen();
    final b = l.finden(nameOderEmail);
    if (b == null || !b.aktiv) return null;
    if (!await passwortPruefen(passwort, b.passwort)) return null;
    final neuerWert = passwortVeraltet(b.passwort) ? await passwortSichern(passwort) : null;
    try {
      await aendern((l) {
        final x = l.nachId(b.id);
        if (x == null) return;
        x.letzteAnmeldung = _jetzt;
        if (neuerWert != null) x.passwort = neuerWert;
      });
    } on Exception {
      // Vermerk ist nicht wichtig genug, um die Anmeldung zu verhindern.
    }
    return b..letzteAnmeldung = _jetzt;
  }

  /// Anmeldung beim Start ein- oder ausschalten.
  Future<void> anmeldungSchalten(bool an) async {
    await aendern((l) {
      if (an && !l.anmeldungMoeglich) {
        throw BenutzerFehler(
            'Die Anmeldung lässt sich erst einschalten, wenn mindestens ein Administrator mit E-Mail-Adresse angelegt ist.');
      }
      l.anmeldungAn = an;
    });
  }

  Future<void> postausgangSetzen(Postausgang? p) async {
    if (p != null && !p.vollstaendig) {
      throw BenutzerFehler('Bitte Server und Absenderadresse des Postausgangs angeben.');
    }
    await aendern((l) => l.postausgang = p);
  }

  // ------------------------------------------------ Passwort vergessen

  /// Erzeugt einen Code (6 Ziffern, 15 Minuten gültig) für ein Konto mit
  /// E-Mail-Adresse und merkt sich nur seinen Prüfwert. Liefert den Code
  /// und das Konto (für den Versand).
  Future<({String code, SvgBenutzer benutzer})> codeErzeugen(String nameOderEmail) async {
    final l = await lesen();
    final b = l.finden(nameOderEmail);
    if (b == null || !b.aktiv) {
      throw BenutzerFehler('Zu „${nameOderEmail.trim()}“ gibt es kein aktives Konto.');
    }
    if (!b.hatEmail) {
      throw BenutzerFehler(
          'Für dieses Konto ist keine E-Mail-Adresse hinterlegt. Bitte einen Administrator bitten, das Passwort zurückzusetzen.');
    }
    final rnd = Random.secure();
    final code = List.generate(6, (_) => rnd.nextInt(10)).join();
    final pruefwert = await passwortSichern(code, durchlaeufe: 20000);
    await aendern((l) {
      l.codes.removeWhere((c) =>
          c['benutzer'] == b.id ||
          (DateTime.tryParse((c['gueltigBis'] ?? '').toString())?.isBefore(_uhr()) ?? true));
      l.codes.add({
        'benutzer': b.id,
        'pruefwert': pruefwert,
        'gueltigBis': _uhr().add(codeGueltigkeit).toIso8601String(),
        'versuche': 0,
      });
    });
    return (code: code, benutzer: b);
  }

  /// Code erzeugen und über den Postausgang des Vereins senden.
  Future<void> codeSenden(String nameOderEmail,
      {required String smtpPasswort, MailVersand? versand}) async {
    final l = await lesen();
    final p = l.postausgang;
    if (p == null || !p.vollstaendig) {
      throw BenutzerFehler(
          'Der Postausgang des Vereins ist noch nicht eingerichtet (Einstellungen › Benutzer und Rechte). Bitte einen Administrator bitten, das Passwort zurückzusetzen.');
    }
    final e = await codeErzeugen(nameOderEmail);
    final text = 'Guten Tag,\n\n'
        'für das Konto „${e.benutzer.anzeigename}“ wurde ein neues Passwort angefordert ($app).\n\n'
        'Code: ${e.code}\n\n'
        'Der Code gilt ${codeGueltigkeit.inMinutes} Minuten. Wer das nicht angefordert hat, kann diese Nachricht ignorieren; das bisherige Passwort bleibt dann gültig.\n\n'
        '${p.absenderName.isEmpty ? p.absenderAdresse : p.absenderName}';
    try {
      await (versand ?? smtpSenden)(
          p, smtpPasswort, e.benutzer.email, 'Code zum Zurücksetzen des Passworts', text);
    } on BenutzerFehler {
      rethrow;
    } catch (f) {
      throw BenutzerFehler('Die E-Mail konnte nicht gesendet werden ($f).');
    }
  }

  /// Mit dem Code ein neues Passwort setzen.
  Future<void> codeEinloesen(String nameOderEmail, String code, String neuesPasswort) async {
    final regel = passwortRegelnPruefen(neuesPasswort);
    if (regel != null) throw BenutzerFehler(regel);
    final l = await lesen();
    final b = l.finden(nameOderEmail);
    final eintrag = b == null ? null : l.codes.where((c) => c['benutzer'] == b.id).firstOrNull;
    final bis = DateTime.tryParse((eintrag?['gueltigBis'] ?? '').toString());
    if (b == null || eintrag == null || bis == null || bis.isBefore(_uhr())) {
      throw BenutzerFehler('Der Code ist abgelaufen oder ungültig. Bitte einen neuen Code anfordern.');
    }
    final richtig = await passwortPruefen(code.trim(), (eintrag['pruefwert'] ?? '').toString());
    if (!richtig) {
      await aendern((l) {
        final c = l.codes.where((c) => c['benutzer'] == b.id).firstOrNull;
        if (c == null) return;
        final v = ((c['versuche'] as num?)?.toInt() ?? 0) + 1;
        if (v >= codeVersuche) {
          l.codes.remove(c);
        } else {
          c['versuche'] = v;
        }
      });
      throw BenutzerFehler('Der Code ist falsch.');
    }
    await passwortSetzen(b.id, neuesPasswort);
  }

  /// Versand über SMTP (Paket mailer).
  static Future<void> smtpSenden(
      Postausgang p, String smtpPasswort, String an, String betreff, String text) async {
    final server = mail.SmtpServer(
      p.server.trim(),
      port: p.port,
      ssl: p.verschluesselung == 'ssl',
      allowInsecure: p.verschluesselung == 'keine',
      username: p.benutzername.trim().isEmpty ? null : p.benutzername.trim(),
      password: smtpPasswort.isEmpty ? null : smtpPasswort,
    );
    final nachricht = mail.Message()
      ..from = mail.Address(p.absenderAdresse.trim(),
          p.absenderName.trim().isEmpty ? null : p.absenderName.trim())
      ..recipients.add(an)
      ..subject = betreff
      ..text = text;
    try {
      await mail.send(nachricht, server, timeout: const Duration(seconds: 30));
    } on mail.MailerException catch (e) {
      throw BenutzerFehler(
          'Die E-Mail konnte nicht gesendet werden: ${e.problems.map((p) => p.msg).join(', ')}');
    }
  }

  static String _neueId() {
    final rnd = Random.secure();
    return 'b-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-'
        '${List.generate(6, (_) => rnd.nextInt(36).toRadixString(36)).join()}';
  }

  // ------------------------------------------------ Passwort-Prüfwerte

  static const _kennung = 'pbkdf2-sha256';
  static const standardDurchlaeufe = 100000;

  /// Erzeugt den Prüfwert (im Hintergrund-Isolate, die Oberfläche hängt nicht).
  static Future<String> passwortSichern(String passwort,
          {int durchlaeufe = standardDurchlaeufe}) =>
      Isolate.run(() => passwortSichernSync(passwort, durchlaeufe: durchlaeufe));

  /// Prüft ein Passwort gegen den Prüfwert (auch alte SHA-256-Werte ohne Salz).
  static Future<bool> passwortPruefen(String passwort, String gespeichert) =>
      Isolate.run(() => passwortPruefenSync(passwort, gespeichert));

  /// Alter Prüfwert ohne Salz?
  static bool passwortVeraltet(String gespeichert) => !gespeichert.startsWith('$_kennung\$');

  static String passwortSichernSync(String passwort, {int durchlaeufe = standardDurchlaeufe}) {
    final rnd = Random.secure();
    final salz = List<int>.generate(16, (_) => rnd.nextInt(256));
    final wert = _pbkdf2(utf8.encode(passwort), salz, durchlaeufe);
    return '$_kennung\$$durchlaeufe\$${base64Url.encode(salz)}\$${base64Url.encode(wert)}';
  }

  static bool passwortPruefenSync(String passwort, String gespeichert) {
    if (gespeichert.isEmpty) return false;
    if (passwortVeraltet(gespeichert)) {
      return sha256.convert(utf8.encode(passwort)).toString() == gespeichert;
    }
    final teile = gespeichert.split('\$');
    if (teile.length != 4) return false;
    final durchlaeufe = int.tryParse(teile[1]) ?? 0;
    if (durchlaeufe <= 0) return false;
    final List<int> salz, erwartet;
    try {
      salz = base64Url.decode(teile[2]);
      erwartet = base64Url.decode(teile[3]);
    } on FormatException {
      return false;
    }
    final wert = _pbkdf2(utf8.encode(passwort), salz, durchlaeufe);
    if (wert.length != erwartet.length) return false;
    var unterschied = 0;
    for (var i = 0; i < wert.length; i++) {
      unterschied |= wert[i] ^ erwartet[i];
    }
    return unterschied == 0;
  }

  static List<int> _pbkdf2(List<int> passwort, List<int> salz, int durchlaeufe) {
    final hmac = Hmac(sha256, passwort);
    var u = hmac.convert([...salz, 0, 0, 0, 1]).bytes;
    final ergebnis = List<int>.from(u);
    for (var i = 1; i < durchlaeufe; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < ergebnis.length; j++) {
        ergebnis[j] ^= u[j];
      }
    }
    return ergebnis;
  }
}
