import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Falsches Passwort oder beschädigte Datei.
class SicherungPasswortFalsch implements Exception {
  const SicherungPasswortFalsch();
  @override
  String toString() =>
      'Das Passwort ist falsch oder die Sicherung ist beschädigt.';
}

/// Verschlüsselte Sicherung – gemeinsam für alle SVG-Apps.
///
/// Verfahren: Schlüssel aus dem Passwort mit PBKDF2-HMAC-SHA256
/// (zufälliges Salz, Zahl der Durchläufe steht in der Datei), Inhalt
/// gzip-komprimiert und mit AES-256-GCM verschlüsselt (zufällige Nonce,
/// Prüfsumme gegen Veränderung). Das Passwort wird nirgends gespeichert;
/// ohne Passwort lässt sich die Sicherung nicht öffnen.
///
/// Die Datei ist JSON mit einem lesbaren Kopf:
/// ```json
/// {"format":"svg-sicherung","version":1,"app":"Kassenbuch",
///  "erstellt":"…","kdf":{"name":"pbkdf2-hmac-sha256","durchlaeufe":200000,
///  "salz":"…"},"verfahren":"aes-256-gcm","nonce":"…","mac":"…","daten":"…"}
/// ```
class SvgSicherung {
  static const format = 'svg-sicherung';
  static const version = 1;
  static const standardDurchlaeufe = 200000;

  /// Mindestlänge für neue Passwörter
  static const mindestLaenge = 8;

  /// Verschlüsselt [inhalt] (z. B. JSON als UTF-8) mit [passwort].
  /// Ergebnis: die Bytes der Sicherungsdatei.
  static Future<Uint8List> verschluesseln(
    List<int> inhalt,
    String passwort, {
    String app = '',
    int durchlaeufe = standardDurchlaeufe,
  }) async {
    if (passwort.length < mindestLaenge) {
      throw ArgumentError(
          'Das Passwort muss mindestens $mindestLaenge Zeichen haben.');
    }
    final zufall = Random.secure();
    List<int> bytes(int n) => List<int>.generate(n, (_) => zufall.nextInt(256));
    final salz = bytes(16);
    final schluessel = await _schluessel(passwort, salz, durchlaeufe);
    final aes = AesGcm.with256bits();
    final box = await aes.encrypt(gzip.encode(inhalt),
        secretKey: schluessel, nonce: bytes(12));
    final kopf = <String, dynamic>{
      'format': format,
      'version': version,
      'app': app,
      'erstellt': DateTime.now().toIso8601String(),
      'hinweis':
          'Verschlüsselte Sicherung (AES-256-GCM). Öffnen nur in der App mit dem Sicherungspasswort.',
      'kdf': {
        'name': 'pbkdf2-hmac-sha256',
        'durchlaeufe': durchlaeufe,
        'salz': base64Encode(salz),
      },
      'verfahren': 'aes-256-gcm',
      'komprimiert': 'gzip',
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
      'daten': base64Encode(box.cipherText),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(kopf)));
  }

  /// Ist [datei] eine verschlüsselte SVG-Sicherung?
  static bool istSicherung(List<int> datei) => kopf(datei) != null;

  /// Lesbarer Kopf (ohne Inhalt) oder null.
  static Map<String, dynamic>? kopf(List<int> datei) {
    try {
      final m = jsonDecode(utf8.decode(datei));
      if (m is Map<String, dynamic> && m['format'] == format) {
        return Map.of(m)..remove('daten');
      }
    } catch (_) {}
    return null;
  }

  /// Entschlüsselt eine Sicherungsdatei. Wirft [SicherungPasswortFalsch].
  static Future<Uint8List> entschluesseln(
      List<int> datei, String passwort) async {
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(utf8.decode(datei)) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Keine SVG-Sicherung.');
    }
    if (m['format'] != format) {
      throw const FormatException('Keine SVG-Sicherung.');
    }
    if ((m['version'] as num? ?? 0) > version) {
      throw const FormatException(
          'Die Sicherung stammt aus einer neueren App-Version.');
    }
    final kdf = Map<String, dynamic>.from(m['kdf'] as Map);
    if (kdf['name'] != 'pbkdf2-hmac-sha256' || m['verfahren'] != 'aes-256-gcm') {
      throw const FormatException('Unbekanntes Verschlüsselungsverfahren.');
    }
    final schluessel = await _schluessel(passwort,
        base64Decode(kdf['salz'] as String), (kdf['durchlaeufe'] as num).toInt());
    final box = SecretBox(base64Decode(m['daten'] as String),
        nonce: base64Decode(m['nonce'] as String),
        mac: Mac(base64Decode(m['mac'] as String)));
    final List<int> klar;
    try {
      klar = await AesGcm.with256bits().decrypt(box, secretKey: schluessel);
    } on SecretBoxAuthenticationError {
      throw const SicherungPasswortFalsch();
    }
    return Uint8List.fromList(
        m['komprimiert'] == 'gzip' ? gzip.decode(klar) : klar);
  }

  static Future<SecretKey> _schluessel(
      String passwort, List<int> salz, int durchlaeufe) {
    final kdf = Pbkdf2(
        macAlgorithm: Hmac.sha256(), iterations: durchlaeufe, bits: 256);
    return kdf.deriveKey(
        secretKey: SecretKey(utf8.encode(passwort)), nonce: salz);
  }
}
