/// Zugriff auf den Inhalt von app_daten.json im Format der
/// Kleingartenverwaltung (Abschnitte stammdaten, mitglieder, gaerten, nextId).
///
/// Arbeitet direkt auf der Map aus [GemeinsameDaten.aendern] – Änderungen
/// landen also unmittelbar im Datenstand, der anschließend geschrieben wird.
/// Unbekannte Felder bleiben unverändert erhalten.
class KgvDaten {
  KgvDaten(this.daten);

  final Map<String, dynamic> daten;

  // ---------------------------------------------------------------- Verein

  Map<String, dynamic> get stammdaten {
    final s = daten['stammdaten'];
    if (s is Map<String, dynamic>) return s;
    final neu = s is Map ? Map<String, dynamic>.from(s) : <String, dynamic>{};
    daten['stammdaten'] = neu;
    return neu;
  }

  String get vereinsname => _text(stammdaten['vereinsname']);
  String get vereinsanschrift => _text(stammdaten['anschrift']);

  /// Ort aus der Anschrift, z. B. „Musterweg 1, 06112 Halle (Saale)“ →
  /// „Halle (Saale)“. Ohne Postleitzahl: der Teil nach dem letzten Komma.
  String get vereinsort {
    final a = vereinsanschrift;
    final plz = RegExp(r'\b\d{5}\s+(.+)$').firstMatch(a);
    if (plz != null) return plz.group(1)!.trim();
    final teile = a.split(',');
    return teile.length > 1 ? teile.last.trim() : '';
  }

  /// Name der ersten Funktionszeile (in der Regel der/die Vorsitzende).
  String get vorsitz => _text(stammdaten['name1']);

  double get pachtPreisProQm => _zahl(stammdaten['pachtPreisProQm']);

  // ------------------------------------------------------------- Parzellen

  List<Map<String, dynamic>> get gaerten => _liste('gaerten');

  /// Einheitliche Schreibweise wie in der Gartenbegehung:
  /// Leerzeichen am Rand weg, Großbuchstaben, „12 a“ → „12 A“.
  static String gartennummer(String text) =>
      text.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');

  Map<String, dynamic>? parzelle(String nummer) {
    final gesucht = gartennummer(nummer);
    for (final g in gaerten) {
      if (gartennummer(_text(g['parzelle'])) == gesucht) return g;
    }
    return null;
  }

  /// Alle Gartennummern, natürlich sortiert (2 vor 10, 12 vor 12A).
  List<String> parzellennummern({bool nurLeerstand = false}) {
    final liste = gaerten
        .where((g) => !nurLeerstand || g['leerstand'] == true)
        .map((g) => _text(g['parzelle']))
        .where((n) => n.isNotEmpty)
        .toList();
    liste.sort(_natuerlich);
    return liste;
  }

  // ----------------------------------------------------------- Mitglieder

  List<Map<String, dynamic>> get mitglieder => _liste('mitglieder');

  Map<String, dynamic>? mitgliedMitId(int id) {
    for (final m in mitglieder) {
      if (m['id'] == id) return m;
    }
    return null;
  }

  /// Pächter einer Parzelle, die zum [stichtag] (Standard: heute) aktiv sind:
  /// istPaechter = true, Eintritt nicht nach und Austritt nicht vor dem
  /// Stichtag.
  List<Map<String, dynamic>> paechterVon(String nummer, {DateTime? stichtag}) {
    final gesucht = gartennummer(nummer);
    final tag = _nurDatum(stichtag ?? DateTime.now());
    return mitglieder.where((m) {
      if (m['istPaechter'] != true) return false;
      if (gartennummer(_text(m['garten'])) != gesucht) return false;
      final eintritt = datumAusKgv(_text(m['eintrittsdatum']));
      if (eintritt != null && eintritt.isAfter(tag)) return false;
      final austritt = datumAusKgv(_text(m['austrittsdatum']));
      return austritt == null || !austritt.isBefore(tag);
    }).toList();
  }

  /// Legt ein neues Mitglied an – genau so, wie es die Kleingartenverwaltung
  /// selbst tut: neue interne Nummer aus nextId, alle üblichen Felder
  /// vorbelegt, dann die übergebenen [felder] darüber.
  ///
  /// Die Mitgliedsnummer bleibt leer, wenn sie nicht übergeben wird; die
  /// Kleingartenverwaltung bildet sie nach ihrer Vorlage.
  Map<String, dynamic> neuesMitglied(Map<String, dynamic> felder) {
    final id = _naechsteId();
    final mitglied = <String, dynamic>{
      'id': id,
      'mitgliedsnummer': '',
      'vorname': '',
      'name': '',
      'garten': '',
      'parkschein': '',
      'geburtstag': '',
      'adresse': '',
      'eintrittsdatum': '',
      'austrittsdatum': '',
      'plz': '',
      'ort': '',
      'telefon': '',
      'email': '',
      'notizen': '',
      'sicherheitsleistung': 0.0,
      'rechnungsempfaenger': true,
      'bankeinzug': false,
      'istMitglied': true,
      'istPaechter': true,
      'hatMahnungen': false,
      'hatAbmahnungen': false,
      'hatKuendigung': false,
      'datenschutzerklaerung': false,
      ...felder,
    };
    mitglied['id'] = id; // darf nicht überschrieben werden
    if (mitglied['garten'] is String) {
      mitglied['garten'] = gartennummer(mitglied['garten'] as String);
    }
    _rohliste('mitglieder').add(mitglied);
    return mitglied;
  }

  /// Trägt bei den bisherigen Pächtern der Parzelle das Austrittsdatum ein
  /// (Tag vor der Übernahme). Die Kleingartenverwaltung erkennt daraus den
  /// Pächterwechsel nach Datum. Mitglieder in [ausser] bleiben unberührt.
  /// Liefert die geänderten Mitglieder.
  List<Map<String, dynamic>> bisherigePaechterAustragen(
    String nummer,
    DateTime uebernahme, {
    Set<int> ausser = const {},
  }) {
    final austritt = uebernahme.subtract(const Duration(days: 1));
    final geaendert = <Map<String, dynamic>>[];
    for (final m in paechterVon(nummer, stichtag: austritt)) {
      if (ausser.contains(m['id'])) continue;
      if (_text(m['austrittsdatum']).isNotEmpty) continue;
      m['austrittsdatum'] = datumKgv(austritt);
      geaendert.add(m);
    }
    return geaendert;
  }

  // ------------------------------------------------------------- Datum

  /// DateTime → „TT.MM.JJJJ“ (Format der Kleingartenverwaltung).
  static String datumKgv(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.'
      '${d.month.toString().padLeft(2, '0')}.${d.year}';

  /// „TT.MM.JJJJ“ (auch „T.M.JJJJ“) oder ISO → DateTime, sonst null.
  static DateTime? datumAusKgv(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    final m = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(t);
    if (m != null) {
      return DateTime(
        int.parse(m.group(3)!),
        int.parse(m.group(2)!),
        int.parse(m.group(1)!),
      );
    }
    final iso = DateTime.tryParse(t);
    return iso == null ? null : _nurDatum(iso);
  }

  // ---------------------------------------------------------- intern

  int _naechsteId() {
    var hoechste = 0;
    for (final m in mitglieder) {
      final id = m['id'];
      if (id is int && id > hoechste) hoechste = id;
    }
    final next = daten['nextId'];
    var id = next is int ? next : hoechste + 1;
    if (id <= hoechste) id = hoechste + 1;
    daten['nextId'] = id + 1;
    return id;
  }

  List<dynamic> _rohliste(String schluessel) {
    final l = daten[schluessel];
    if (l is List) return l;
    final neu = <dynamic>[];
    daten[schluessel] = neu;
    return neu;
  }

  /// Die Einträge selbst sind dieselben Objekte wie in [daten] –
  /// Änderungen an einem Eintrag wirken also direkt.
  List<Map<String, dynamic>> _liste(String schluessel) =>
      _rohliste(schluessel).whereType<Map<String, dynamic>>().toList();

  static String _text(Object? wert) => (wert ?? '').toString().trim();

  static double _zahl(Object? wert) {
    if (wert is num) return wert.toDouble();
    return double.tryParse(_text(wert).replaceAll(',', '.')) ?? 0;
  }

  static DateTime _nurDatum(DateTime d) => DateTime(d.year, d.month, d.day);

  static int _natuerlich(String a, String b) {
    final ma = RegExp(r'^(\d+)(.*)$').firstMatch(a.trim());
    final mb = RegExp(r'^(\d+)(.*)$').firstMatch(b.trim());
    if (ma != null && mb != null) {
      final c = int.parse(ma.group(1)!).compareTo(int.parse(mb.group(1)!));
      if (c != 0) return c;
      return ma.group(2)!.compareTo(mb.group(2)!);
    }
    if (ma != null) return -1;
    if (mb != null) return 1;
    return a.compareTo(b);
  }
}
