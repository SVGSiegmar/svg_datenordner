import 'dart:convert';
import 'dart:io';

// Importregeln der SVG-Apps (Bauplan „Importregeln“, festgelegt 25.11.2026).
// Ab svg_datenordner 0.6.0 gemeinsam für alle Apps (zuerst im Kassenbuch
// gebaut und getestet). Das Lesen von Excel-Dateien bleibt in den Apps,
// weil es das Paket „excel“ braucht; sie liefern dafür eine ImportTabelle.
//
// Reine Funktionen ohne App-Zustand: Sie bereinigen Werte aus Tabellen der
// Vereine (Excel, CSV) nach festen Regeln. Was sie ändern oder nicht
// verstehen, melden sie zurück, damit die Vorschau es zeigen kann – nichts
// wird stillschweigend geändert.

// ------------------------------------------------------------ Zeichensatz --

/// Ergebnis beim Lesen einer Textdatei (CSV).
class ImportText {
  const ImportText(this.text, this.zeichensatz,
      {this.zweifel = false, this.andereFassung = ''});

  final String text;

  /// „UTF-8“, „UTF-8 mit Kennung“ oder „Windows-1252“.
  final String zeichensatz;

  /// Zeichensatz nicht sicher erkannt: beide Fassungen zeigen und fragen.
  final bool zweifel;
  final String andereFassung;
}

const _windows1252 = <int, int>{
  0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
  0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
  0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
  0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
  0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
  0x9E: 0x017E, 0x9F: 0x0178,
};

/// Anzeigename des Zeichensatzes (in den Apple-Fassungen ohne Plattformnamen).
String zeichensatzAnzeige(String z) => z == 'Windows-1252'
    ? (Platform.isIOS || Platform.isMacOS ? 'ANSI (westeuropäisch)' : 'Windows-1252 (ANSI)')
    : z;

String windows1252Lesen(List<int> bytes) =>
    String.fromCharCodes(bytes.map((b) => _windows1252[b] ?? b));

/// Erkennt UTF-8 (mit oder ohne Kennung) und Windows-1252. Mit [zeichensatz]
/// („UTF-8“ oder „Windows-1252“) wird die Wahl des Vereins verwendet.
ImportText importTextLesen(List<int> bytes, {String? zeichensatz}) {
  var daten = bytes;
  final kennung = daten.length >= 3 &&
      daten[0] == 0xEF &&
      daten[1] == 0xBB &&
      daten[2] == 0xBF;
  if (kennung) daten = daten.sublist(3);
  if (zeichensatz == 'Windows-1252') {
    return ImportText(windows1252Lesen(daten), 'Windows-1252');
  }
  if (zeichensatz == 'UTF-8') {
    return ImportText(utf8.decode(daten, allowMalformed: true), 'UTF-8');
  }
  if (kennung) {
    return ImportText(
        utf8.decode(daten, allowMalformed: true), 'UTF-8 mit Kennung');
  }
  try {
    return ImportText(utf8.decode(daten), 'UTF-8');
  } on FormatException {
    // Bytes, die es in Windows-1252 nicht gibt, deuten auf einen ganz
    // anderen Zeichensatz: dann fragen.
    final fremd = daten
        .any((b) => b == 0x81 || b == 0x8D || b == 0x8F || b == 0x90 || b == 0x9D);
    return ImportText(windows1252Lesen(daten), 'Windows-1252',
        zweifel: fremd,
        andereFassung: fremd ? utf8.decode(daten, allowMalformed: true) : '');
  }
}

// -------------------------------------------------------------------- CSV --

/// Zerlegt CSV-Text in Datensätze und Felder. Anführungszeichen schützen
/// Trennzeichen und Zeilenumbrüche (mehrzeilige Verwendungszwecke), "" steht
/// für ein Anführungszeichen.
List<List<String>> csvZerlegen(String text, String trenner) {
  final ergebnis = <List<String>>[];
  var felder = <String>[];
  final feld = StringBuffer();
  var inAnf = false;
  var feldBegonnen = false;
  void feldEnde() {
    felder.add(feld.toString().trim());
    feld.clear();
    feldBegonnen = false;
  }

  void zeileEnde() {
    feldEnde();
    if (felder.any((f) => f.isNotEmpty)) ergebnis.add(felder);
    felder = <String>[];
  }

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inAnf) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          feld.write('"');
          i++;
        } else {
          inAnf = false;
        }
      } else {
        feld.write(c);
      }
      continue;
    }
    if (c == '"' && (!feldBegonnen || feld.toString().trim().isEmpty)) {
      feld.clear();
      inAnf = true;
      feldBegonnen = true;
    } else if (c == trenner) {
      feldEnde();
    } else if (c == '\n') {
      zeileEnde();
    } else if (c == '\r') {
      // \r\n: Zeilenende kommt mit \n
      if (i + 1 >= text.length || text[i + 1] != '\n') zeileEnde();
    } else {
      feld.write(c);
      feldBegonnen = true;
    }
  }
  if (feld.isNotEmpty || felder.isNotEmpty) zeileEnde();
  return ergebnis;
}

/// Zeilen der Datei, Zeilenumbrüche in Anführungszeichen bleiben im Feld.
List<String> _csvRohzeilen(String text) {
  final zeilen = <String>[];
  final puffer = StringBuffer();
  var inAnf = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '"') inAnf = !inAnf;
    if (!inAnf && (c == '\n' || c == '\r')) {
      if (puffer.isNotEmpty) zeilen.add(puffer.toString());
      puffer.clear();
      continue;
    }
    puffer.write(c);
  }
  if (puffer.isNotEmpty) zeilen.add(puffer.toString());
  return zeilen;
}

int _zaehleAusserhalb(String zeile, String zeichen) {
  var n = 0;
  var inAnf = false;
  for (var i = 0; i < zeile.length; i++) {
    final c = zeile[i];
    if (c == '"') {
      inAnf = !inAnf;
    } else if (!inAnf && c == zeichen) {
      n++;
    }
  }
  return n;
}

/// Trennzeichen erkennen: In den ersten Zeilen Semikolon, Komma und Tabulator
/// außerhalb von Anführungszeichen zählen. Es gilt das Zeichen, das in den
/// meisten aufeinanderfolgenden Zeilen gleich oft vorkommt (Kopf- und
/// Datenzeilen; Kontoangaben darüber zählen nicht). Ist das nicht eindeutig,
/// ist [zeichen] leer und [kandidaten] nennt die Möglichkeiten zum Fragen.
({String? zeichen, List<String> kandidaten}) csvTrennzeichenErkennen(
    String text) {
  final zeilen =
      _csvRohzeilen(text).where((z) => z.trim().isNotEmpty).take(30).toList();
  if (zeilen.isEmpty) return (zeichen: null, kandidaten: const []);
  final laenge = <String, int>{};
  for (final t in const [';', ',', '\t']) {
    final anzahl = zeilen.map((z) => _zaehleAusserhalb(z, t)).toList();
    var besteLaenge = 0, besterStart = 0;
    var start = 0;
    for (var i = 1; i <= anzahl.length; i++) {
      if (i == anzahl.length || anzahl[i] != anzahl[start]) {
        final l = i - start;
        if (anzahl[start] > 0 && l > besteLaenge) {
          besteLaenge = l;
          besterStart = start;
        }
        start = i;
      }
    }
    if (besteLaenge == 0) continue;
    // Die gleichmäßige Strecke muss bis (fast) zum Ende reichen.
    final bisEnde = anzahl.length - besterStart;
    if (besteLaenge >= 0.9 * bisEnde || besteLaenge >= bisEnde - 1) {
      laenge[t] = besteLaenge;
    }
  }
  if (laenge.isEmpty) return (zeichen: null, kandidaten: const [';', ',', '\t']);
  final sortiert = laenge.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  if (sortiert.length == 1 || sortiert[0].value > sortiert[1].value) {
    return (zeichen: sortiert.first.key, kandidaten: [sortiert.first.key]);
  }
  return (
    zeichen: null,
    kandidaten: sortiert
        .where((e) => e.value == sortiert.first.value)
        .map((e) => e.key)
        .toList()
  );
}

String trennzeichenName(String t) => switch (t) {
      ';' => 'Semikolon (;)',
      ',' => 'Komma (,)',
      '\t' => 'Tabulator',
      _ => '„$t“',
    };

// ----------------------------------------------------------------- Zahlen --

enum ZahlenFormat { deutsch, englisch, unklar }

final _einheiten = RegExp(r'(€|eur(o)?\b|m²|m³|m2\b|m3\b|qm\b|kwh\b)',
    caseSensitive: false);

String _zahlVorbereiten(String s) => s
    .replaceAll(_einheiten, '')
    .replaceAll(RegExp('[\\s   ]'), '')
    .replaceAll('−', '-')
    .replaceAll('–', '-');

String _ohneVorzeichen(String w) {
  var x = w;
  if (x.startsWith('-') || x.startsWith('+')) x = x.substring(1);
  if (x.endsWith('-')) x = x.substring(0, x.length - 1);
  return x;
}

/// Wissenschaftliche Schreibweise (3,45E+08): Excel hat eine lange Nummer
/// als Zahl gespeichert, Stellen sind verloren.
bool istWissenschaftlich(String s) =>
    RegExp(r'^\s*-?\d+([.,]\d+)?[eE][+-]?\d+\s*$').hasMatch(s);

/// Zahlenformat einer Spalte bestimmen – je Spalte, nicht je Zelle:
/// „1.234,56“ macht die Spalte deutsch, „1,234.56“ englisch.
ZahlenFormat zahlenFormatErkennen(Iterable<String> werte) {
  var de = false, en = false;
  for (final roh in werte) {
    final w = _ohneVorzeichen(_zahlVorbereiten(roh));
    if (w.isEmpty || istWissenschaftlich(w)) continue;
    if (RegExp(r'^\d{1,3}(\.\d{3})+,\d+$').hasMatch(w) ||
        RegExp(r'^\d+,(\d{1,2}|\d{4,})$').hasMatch(w) ||
        RegExp(r'^0,\d+$').hasMatch(w) ||
        RegExp(r'^\d{4,},\d{3}$').hasMatch(w) ||
        RegExp(r'^\d{1,3}(\.\d{3}){2,}$').hasMatch(w)) {
      de = true;
    } else if (RegExp(r'^\d{1,3}(,\d{3})+\.\d+$').hasMatch(w) ||
        RegExp(r'^\d+\.(\d{1,2}|\d{4,})$').hasMatch(w) ||
        RegExp(r'^0\.\d+$').hasMatch(w) ||
        RegExp(r'^\d{4,}\.\d{3}$').hasMatch(w) ||
        RegExp(r'^\d{1,3}(,\d{3}){2,}$').hasMatch(w)) {
      en = true;
    }
  }
  if (de && !en) return ZahlenFormat.deutsch;
  if (en && !de) return ZahlenFormat.englisch;
  return ZahlenFormat.unklar;
}

/// Spalte ist nur dann mehrdeutig, wenn ein Wert wie „1.234“ oder „235,142“
/// vorkommt und das Format nicht feststeht. Liefert dann ein Beispiel.
String? zahlenSpalteMehrdeutig(Iterable<String> werte) {
  if (zahlenFormatErkennen(werte) != ZahlenFormat.unklar) return null;
  for (final roh in werte) {
    final w = _ohneVorzeichen(_zahlVorbereiten(roh));
    if (RegExp(r'^\d{1,3}[.,]\d{3}$').hasMatch(w)) return roh.trim();
  }
  return null;
}

/// Zahl lesen: Einheiten (€, m², m³, kWh), Leerzeichen und geschützte
/// Leerzeichen entfernen, Minus vorn oder hinten erkennen. Bei
/// [ZahlenFormat.unklar] gilt die deutsche Schreibweise.
double? zahlLesen(String roh, [ZahlenFormat format = ZahlenFormat.deutsch]) {
  var w = _zahlVorbereiten(roh);
  if (w.isEmpty || istWissenschaftlich(w)) return null;
  var negativ = false;
  if (w.startsWith('-')) {
    negativ = true;
    w = w.substring(1);
  } else if (w.startsWith('+')) {
    w = w.substring(1);
  }
  if (w.endsWith('-')) {
    negativ = true;
    w = w.substring(0, w.length - 1);
  }
  if (format == ZahlenFormat.englisch) {
    w = w.replaceAll(',', '');
  } else if (w.contains(',')) {
    w = w.replaceAll('.', '').replaceAll(',', '.');
  } else if (RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(w)) {
    w = w.replaceAll('.', '');
  }
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(w)) return null;
  final z = double.tryParse(w);
  if (z == null) return null;
  return negativ ? -z : z;
}

/// Zahl ohne überflüssige Nachkommastellen für die Vorschau.
String zahlText(double z) {
  if (z == z.roundToDouble() && z.abs() < 1e15) return z.toInt().toString();
  return z.toString().replaceAll('.', ',');
}

// ------------------------------------------------------------------ Datum --

enum DatumsFolge { tagMonat, monatTag, unklar }

/// Excel speichert ein Datum als Zahl der Tage seit dem 30.12.1899.
DateTime? excelDatumszahl(num n) {
  if (n < 1 || n > 2958465) return null;
  final d = DateTime.utc(1899, 12, 30).add(Duration(days: n.floor()));
  return DateTime(d.year, d.month, d.day);
}

final _tmj = RegExp(r'^(\d{1,2})([./-])(\d{1,2})\2(\d{2}|\d{4})$');

/// TT/MM gegen MM/TT nie raten: Ein Wert über 12 in der Spalte entscheidet.
/// Mit Punkt geschrieben gilt immer Tag.Monat.
DatumsFolge datumsFolgeErkennen(Iterable<String> werte) {
  var tagVorn = false, monatVorn = false, nurPunkt = true, gesehen = false;
  for (final roh in werte) {
    final m = _tmj.firstMatch(roh.trim().split(RegExp(r'[ T]')).first);
    if (m == null) continue;
    gesehen = true;
    if (m.group(2) != '.') nurPunkt = false;
    final a = int.parse(m.group(1)!), b = int.parse(m.group(3)!);
    if (a > 12) tagVorn = true;
    if (b > 12) monatVorn = true;
  }
  if (tagVorn && !monatVorn) return DatumsFolge.tagMonat;
  if (monatVorn && !tagVorn) return DatumsFolge.monatTag;
  if (gesehen && nurPunkt && !monatVorn) return DatumsFolge.tagMonat;
  if (!gesehen) return DatumsFolge.tagMonat;
  return DatumsFolge.unklar;
}

/// Datum lesen: TT.MM.JJJJ, JJJJ-MM-TT, zweistellige Jahre (00–69 → 20xx),
/// Excel-Datumszahl als Text (nur mit [excelZahl]). Ein Jahr allein bleibt
/// ein Jahr (Ergebnis null). Bei [DatumsFolge.unklar] und Schrägstrich ohne
/// Wert über 12 ebenfalls null – dann fragen.
DateTime? datumLesen(String roh,
    {DatumsFolge folge = DatumsFolge.tagMonat, bool excelZahl = false}) {
  final s = roh.trim().split(RegExp(r'[ T]')).first;
  if (s.isEmpty) return null;
  DateTime? gueltig(int j, int m, int t) {
    if (m < 1 || m > 12 || t < 1 || t > 31) return null;
    final d = DateTime(j, m, t);
    return d.month == m && d.day == t ? d : null;
  }

  final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(s);
  if (iso != null) {
    return gueltig(int.parse(iso.group(1)!), int.parse(iso.group(2)!),
        int.parse(iso.group(3)!));
  }
  final m = _tmj.firstMatch(s);
  if (m != null) {
    final a = int.parse(m.group(1)!), b = int.parse(m.group(3)!);
    var j = int.parse(m.group(4)!);
    if (m.group(4)!.length == 2) j += j < 70 ? 2000 : 1900;
    if (m.group(2) == '.') return gueltig(j, b, a);
    if (a > 12) return gueltig(j, b, a);
    if (b > 12) return gueltig(j, a, b);
    if (a == b) return gueltig(j, a, b);
    return switch (folge) {
      DatumsFolge.tagMonat => gueltig(j, b, a),
      DatumsFolge.monatTag => gueltig(j, a, b),
      DatumsFolge.unklar => null,
    };
  }
  if (excelZahl && RegExp(r'^\d{5}([.,]\d+)?$').hasMatch(s)) {
    final n = double.tryParse(s.replaceAll(',', '.'));
    if (n != null && n >= 20000 && n <= 80000) return excelDatumszahl(n);
  }
  return null;
}

String datumText(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

// ------------------------------------------------------------ Platzhalter --

/// „????“, „-“, „keine Uhr“, „n. v.“ und Leertext gelten als leer.
bool istPlatzhalter(String s) {
  final w = s.trim().toLowerCase();
  if (w.isEmpty) return true;
  if (RegExp(r'^[?]+$').hasMatch(w)) return true;
  return const {
    '-', '--', '---', '–', '—', 'n. v.', 'n.v.', 'n/v', 'nv', 'k. a.',
    'k.a.', 'keine uhr', 'kein zähler', 'kein zaehler',
  }.contains(w);
}

// ----------------------------------------------------------- Gartennummer --

/// Präfixe („Garten“, „Parzelle“, „Nr.“) und führende Nullen entfernen,
/// Leerzeichen vor Buchstaben entfernen, Buchstaben klein:
/// „Garten 01“ → 1, „58 a“ → 58a.
String gartennummerNormalisieren(String roh) {
  var w = roh.trim().toLowerCase();
  w = w.replaceFirst(
      RegExp(r'^(garten|parzelle|parz\.?|nummer|nr\.?|g\.)\s*(nr\.?|nummer)?\s*'),
      '');
  w = w.replaceAll(RegExp(r'\s+(?=[a-zäöü])'), '');
  w = w.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  if (RegExp(r'^\d+\.0$').hasMatch(w)) w = w.substring(0, w.length - 2);
  return w.trim();
}

bool istGartennummer(String roh) => RegExp(r'^\d+([.,/]\d+)?[a-z]?$')
    .hasMatch(gartennummerNormalisieren(roh));

// ------------------------------------------- Telefon, PLZ, Nummern als Text --

/// Telefon immer als Text. Fehlt bei 8–11 Ziffern die führende 0 (von Excel
/// entfernt), wird sie ergänzt und markiert. +49, Klammern, Leerzeichen und
/// Schrägstriche bleiben. Wissenschaftliche Schreibweise ist ein Fehler.
({String wert, bool ergaenzt, bool fehler}) telefonNormalisieren(Object? roh) {
  if (roh == null) return (wert: '', ergaenzt: false, fehler: false);
  if (roh is num) {
    if (roh != roh.roundToDouble()) {
      return (wert: roh.toString(), ergaenzt: false, fehler: true);
    }
    roh = roh.toInt().toString();
  }
  final s = roh.toString().trim();
  if (istWissenschaftlich(s)) return (wert: s, ergaenzt: false, fehler: true);
  if (RegExp(r'^[1-9]\d{7,10}$').hasMatch(s)) {
    return (wert: '0$s', ergaenzt: true, fehler: false);
  }
  return (wert: s, ergaenzt: false, fehler: false);
}

/// PLZ immer als Text mit fünf Ziffern: 6258 → 06258.
String plzNormalisieren(Object? roh) {
  if (roh == null) return '';
  final s = roh is num ? roh.toInt().toString() : roh.toString().trim();
  if (RegExp(r'^\d{3,4}$').hasMatch(s)) return s.padLeft(5, '0');
  return s;
}

/// Zähler-, Mitglieds- und Uhrnummern immer als Text, führende Nullen
/// bleiben. Kommt die Nummer als Zahl, können Nullen verloren sein:
/// [alsZahl] ist dann wahr, die Vorschau markiert den Wert.
({String wert, bool alsZahl}) nummerAlsText(Object? roh) {
  if (roh == null) return (wert: '', alsZahl: false);
  if (roh is num) return (wert: zahlText(roh.toDouble()), alsZahl: true);
  return (wert: roh.toString().trim(), alsZahl: false);
}

// ------------------------------------------------------------------- IBAN --

/// Leerzeichen entfernen, Großbuchstaben, Prüfziffer prüfen. Eine als Zahl
/// gespeicherte IBAN ist immer ein Fehler (Excel hat Stellen abgeschnitten).
({String iban, bool gueltig, String fehler}) ibanPruefen(Object? roh) {
  const alsZahl =
      'IBAN als Zahl gespeichert – Excel hat Stellen abgeschnitten, sie ist nicht wiederherstellbar';
  if (roh == null) return (iban: '', gueltig: false, fehler: '');
  if (roh is num) return (iban: '', gueltig: false, fehler: alsZahl);
  final s = roh.toString().replaceAll(RegExp('[\\s ]'), '').toUpperCase();
  if (s.isEmpty) return (iban: '', gueltig: false, fehler: '');
  if (istWissenschaftlich(s) || RegExp(r'^\d+([.,]\d+)?$').hasMatch(s)) {
    return (iban: '', gueltig: false, fehler: alsZahl);
  }
  if (!RegExp(r'^[A-Z]{2}\d{2}[A-Z0-9]{10,30}$').hasMatch(s) ||
      (s.startsWith('DE') && s.length != 22)) {
    return (iban: s, gueltig: false, fehler: 'keine gültige IBAN');
  }
  final umgestellt = s.substring(4) + s.substring(0, 4);
  var rest = 0;
  for (final c in umgestellt.codeUnits) {
    if (c >= 48 && c <= 57) {
      rest = (rest * 10 + (c - 48)) % 97;
    } else {
      rest = (rest * 100 + (c - 55)) % 97;
    }
  }
  return rest == 1
      ? (iban: s, gueltig: true, fehler: '')
      : (iban: s, gueltig: false, fehler: 'Prüfziffer der IBAN stimmt nicht');
}

// ------------------------------------------------- Summen- und Fußzeilen --

final _summenWort = RegExp(
    r'(?<![a-zäöüß])(summe|summen|gesamt|gesamtsumme|zwischensumme|endsumme|insgesamt|übertrag|uebertrag|gartenflächen|gartenflaechen|hauptuhr|hauptzähler|hauptzaehler|parkflächen|parkflaechen|verwaltungsauftrag)(?![a-zäöüß])',
    caseSensitive: false);

/// Zeile mit Wörtern wie „Summe“, „Gesamt“, „Gartenflächen“, „Hauptuhr“.
/// Ob sie übernommen wird, entscheidet der Aufrufer (z. B. nur ohne gültige
/// Gartennummer bzw. ohne Datum).
String? summenWort(Iterable<String> texte) {
  for (final t in texte) {
    // klein schreiben, damit auch „Übertrag“ sicher erkannt wird
    final m = _summenWort.firstMatch(t.toLowerCase());
    if (m != null && m.end <= t.length) return t.substring(m.start, m.end);
  }
  return null;
}

// --------------------------------------------------------- Tabellenmodell --

/// Eine Zelle, wie sie in der Datei steht: Text, Zahl (double), Datum
/// (DateTime) oder leer. Excel-Zahlen und -Datumswerte kommen aus der Zelle
/// selbst, nicht aus dem angezeigten Text.
class ImportZelle {
  const ImportZelle(this.wert);
  final Object? wert;

  bool get leer =>
      wert == null || (wert is String && (wert as String).trim().isEmpty);

  /// Text für Vorschau und Textfelder.
  String get text {
    final w = wert;
    if (w == null) return '';
    if (w is double) return zahlText(w);
    if (w is DateTime) return datumText(w);
    return w.toString().trim();
  }
}

/// Eine eingelesene Tabelle (ein Tabellenblatt oder eine CSV-Datei).
class ImportTabelle {
  ImportTabelle({
    required this.quelle,
    required this.format,
    required this.kopf,
    required this.zeilen,
    required this.zeilenNummern,
    this.blatt = '',
    this.blaetter = const [],
    this.kopfZeilenNummer = 1,
    this.ausgeblendeteZeilen = const {},
    this.ausgeblendeteSpalten = const {},
    this.kommentare = const {},
    this.zeichensatz = '',
    this.trenner = '',
  });

  final String quelle;

  /// „Excel“ oder „CSV“.
  final String format;
  final String blatt;

  /// Alle Tabellenblätter mit Inhalt (zum Wählen).
  final List<String> blaetter;
  final List<String> kopf;
  final List<List<ImportZelle>> zeilen;

  /// Zeilennummer in der Datei (ab 1) je Datenzeile.
  final List<int> zeilenNummern;
  final int kopfZeilenNummer;
  final Set<int> ausgeblendeteZeilen;
  final Set<int> ausgeblendeteSpalten;

  /// Zellkommentare: Schlüssel „Zeilennummer:Spalte“ (Spalte ab 0).
  final Map<String, String> kommentare;
  final String zeichensatz;
  final String trenner;

  int get spalten => kopf.length;

  ImportZelle zelle(int zeile, int spalte) {
    final z = zeilen[zeile];
    return spalte >= 0 && spalte < z.length ? z[spalte] : const ImportZelle(null);
  }

  String? kommentar(int zeile, int spalte) =>
      kommentare['${zeilenNummern[zeile]}:$spalte'];

  bool ausgeblendet(int zeile) =>
      ausgeblendeteZeilen.contains(zeilenNummern[zeile]);

  String spaltenName(int s) {
    final k = s < kopf.length ? kopf[s].trim() : '';
    return k.isEmpty
        ? 'Spalte ${spaltenBuchstabe(s)} (ohne Überschrift)'
        : k;
  }

  /// Bis zu [anzahl] Beispielwerte einer Spalte.
  List<String> beispiele(int s, [int anzahl = 3]) => [
        for (var i = 0; i < zeilen.length; i++)
          if (!zelle(i, s).leer) zelle(i, s).text,
      ].take(anzahl).toList();

  /// Texte einer Spalte (für die Formaterkennung).
  List<String> spaltenTexte(int s) => [
        for (var i = 0; i < zeilen.length; i++)
          if (zelle(i, s).wert is String && !zelle(i, s).leer) zelle(i, s).text,
      ];
}

String spaltenBuchstabe(int index) {
  var n = index + 1;
  var s = '';
  while (n > 0) {
    final r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

/// Erste Zeile mit mehreren Texten ist die Überschrift. Leerzeilen und
/// Titelzeilen davor werden übersprungen.
int kopfzeileFinden(List<List<ImportZelle>> zeilen) {
  bool istText(ImportZelle z) =>
      z.wert is String &&
      !z.leer &&
      zahlLesen(z.text) == null &&
      datumLesen(z.text) == null;
  for (var i = 0; i < zeilen.length && i < 30; i++) {
    final texte = zeilen[i].where(istText).length;
    if (texte < 2) continue;
    final naechste = zeilen
        .skip(i + 1)
        .firstWhere((z) => z.any((c) => !c.leer), orElse: () => const []);
    final gefuellt = naechste.where((c) => !c.leer).length;
    if (naechste.isEmpty || texte * 2 >= gefuellt) return i;
  }
  return 0;
}

/// Rückfrage beim Einlesen (Trennzeichen oder Zeichensatz unklar). Die
/// Oberfläche fragt den Verein und liest mit der Antwort noch einmal.
class ImportRueckfrage implements Exception {
  ImportRueckfrage(this.art, this.frage, this.optionen);

  /// „trenner“ oder „zeichensatz“.
  final String art;
  final String frage;

  /// Wert → Beschreibung (mit Beispiel).
  final Map<String, String> optionen;

  @override
  String toString() => frage;
}

/// CSV als Tabelle einlesen. Wirft [ImportRueckfrage], wenn Trennzeichen oder
/// Zeichensatz nicht eindeutig sind und nicht vorgegeben wurden.
ImportTabelle importTabelleAusCsv(List<int> bytes, String quelle,
    {String? trenner, String? zeichensatz}) {
  final gelesen = importTextLesen(bytes, zeichensatz: zeichensatz);
  if (gelesen.zweifel && zeichensatz == null) {
    String probe(String t) => t
        .split(RegExp(r'\r?\n'))
        .where((z) => z.trim().isNotEmpty)
        .take(3)
        .join('\n');
    throw ImportRueckfrage(
        'zeichensatz',
        'Der Zeichensatz von „$quelle“ ist nicht eindeutig. Welche Fassung ist richtig lesbar?',
        {
          'Windows-1252': '${zeichensatzAnzeige('Windows-1252')}:\n${probe(gelesen.text)}',
          'UTF-8': 'UTF-8:\n${probe(gelesen.andereFassung)}',
        });
  }
  final text = gelesen.text;
  var t = trenner;
  if (t == null) {
    final erkannt = csvTrennzeichenErkennen(text);
    if (erkannt.zeichen == null) {
      final zeile = _csvRohzeilen(text)
          .firstWhere((z) => z.trim().isNotEmpty, orElse: () => '');
      throw ImportRueckfrage(
          'trenner',
          'In „$quelle“ ist das Trennzeichen nicht eindeutig. Erste Zeile:\n$zeile',
          {for (final kand in erkannt.kandidaten) kand: trennzeichenName(kand)});
    }
    t = erkannt.zeichen!;
  }
  final roh = csvZerlegen(text, t);
  final zellen = roh
      .map((z) => z.map((f) => ImportZelle(f.trim().isEmpty ? null : f)).toList())
      .toList();
  if (zellen.isEmpty) throw Exception('„$quelle“ ist leer.');
  final k = kopfzeileFinden(zellen);
  final breite = zellen.fold<int>(0, (m, z) => z.length > m ? z.length : m);
  final kopf = List<String>.generate(
      breite, (i) => i < zellen[k].length ? zellen[k][i].text : '');
  // Datensätze ohne Leerzeilen: Nummer = Datensatz ab 1
  return ImportTabelle(
    quelle: quelle,
    format: 'CSV',
    kopf: kopf,
    zeilen: zellen.sublist(k + 1),
    zeilenNummern: [for (var i = k + 1; i < zellen.length; i++) i + 1],
    kopfZeilenNummer: k + 1,
    zeichensatz: gelesen.zeichensatz,
    trenner: t,
  );
}
