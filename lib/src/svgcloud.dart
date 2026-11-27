import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Anbindung an die SVGCloud des Stadtverbands (Datei-API).
///
/// Kein Ordner-Abgleich: Die Apps lesen und schreiben ihre Dateien direkt.
/// Die Versionsnummer des Servers (`expected_version`) ersetzt dabei die
/// Sperrdatei: Hat ein anderes Gerät inzwischen gespeichert, lehnt der
/// Server ab, und die App fragt wie bisher „Neu laden oder meine Fassung“.
///
/// Der Geräte-Token wird nie im Klartext in Vereinsdaten gespeichert,
/// sondern über einen [SvgCloudTokenSpeicher], den jede App mit dem
/// sicheren Speicher des Systems umsetzt (z. B. flutter_secure_storage:
/// Schlüsselbund auf Apple-Geräten, Anmeldeinformationen unter Windows,
/// Keystore unter Android).

// ------------------------------------------------------------------ Fehler

/// Allgemeiner Fehler der SVGCloud mit einem Satz für den Benutzer.
class SvgCloudFehler implements Exception {
  SvgCloudFehler(this.meldung, {this.status});

  /// Verständlicher Satz für eine Meldung in der App.
  final String meldung;

  /// HTTP-Status, falls der Server geantwortet hat.
  final int? status;

  @override
  String toString() => 'SvgCloudFehler${status == null ? '' : ' ($status)'}: $meldung';
}

/// Das Gerät ist nicht (mehr) gekoppelt: Verbindungsschlüssel neu eingeben.
class SvgCloudNichtGekoppelt extends SvgCloudFehler {
  SvgCloudNichtGekoppelt([String? meldung])
      : super(meldung ??
            'Dieses Gerät ist nicht mit der SVGCloud verbunden. Bitte den '
                'Verbindungsschlüssel des Vereins neu eingeben.',
            status: 401);
}

/// Das Programm darf an dieser Stelle des Vereinsordners nicht schreiben
/// (Schreibrechte je Programm auf dem Server, HTTP 403).
class SvgCloudKeinSchreibrecht extends SvgCloudFehler {
  SvgCloudKeinSchreibrecht(String pfad, [String? server])
      : super('Dieses Programm darf „$pfad“ in der SVGCloud nicht speichern.'
            '${server == null || server.isEmpty ? '' : ' ($server)'}',
            status: 403);
}

/// Keine Verbindung zum Server (kein Internet, Server nicht erreichbar).
class SvgCloudOffline extends SvgCloudFehler {
  SvgCloudOffline([String? technisch])
      : super('Keine Verbindung zur SVGCloud. Es wird mit dem zuletzt '
            'geladenen Stand weitergearbeitet; gespeichert wird, sobald die '
            'Verbindung wieder da ist.${technisch == null ? '' : ' ($technisch)'}');
}

/// Die Datei wurde inzwischen von einem anderen Gerät geändert.
class SvgCloudVersionKonflikt extends SvgCloudFehler {
  SvgCloudVersionKonflikt(this.pfad, this.aktuelleVersion)
      : super('„$pfad“ wurde inzwischen auf einem anderen Gerät gespeichert. '
            'Bitte neu laden.',
            status: 409);

  final String pfad;

  /// Version auf dem Server, falls er sie mitteilt (sonst null).
  final int? aktuelleVersion;
}

// ------------------------------------------------------------ Token-Speicher

/// Ort, an dem eine App den Geräte-Token sicher ablegt.
abstract class SvgCloudTokenSpeicher {
  Future<String?> lesen();
  Future<void> speichern(String token);
  Future<void> loeschen();
}

/// Nur für Tests und Probeläufe: hält den Token im Arbeitsspeicher.
class SvgCloudTokenImSpeicher implements SvgCloudTokenSpeicher {
  SvgCloudTokenImSpeicher([this._token]);
  String? _token;
  @override
  Future<String?> lesen() async => _token;
  @override
  Future<void> speichern(String token) async => _token = token;
  @override
  Future<void> loeschen() async => _token = null;
}

// ------------------------------------------------------------------ Datei

/// Eine Datei im gemeinsamen Vereinsbereich der SVGCloud.
class CloudDatei {
  CloudDatei({
    required this.id,
    required this.pfad,
    required this.version,
    this.groesse = 0,
    this.geaendert,
  });

  final String id;

  /// Pfad wie im Datenordner, immer mit „/“, z. B. `daten/app_daten.json`.
  final String pfad;
  final int version;
  final int groesse;
  final DateTime? geaendert;

  /// Liest die Angaben des Servers. Verträgt verschiedene Schreibweisen
  /// (file_id/id, path/name, updated_at/modified …).
  static CloudDatei? ausJson(Object? roh) {
    if (roh is! Map) return null;
    String text(List<String> namen) {
      for (final n in namen) {
        final v = roh[n];
        if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
      }
      return '';
    }

    int zahl(List<String> namen) => int.tryParse(text(namen)) ?? 0;
    final pfad = SvgCloudVerbindung.pfadNormal(text(['path', 'pfad', 'relative_path', 'name', 'filename']));
    final id = text(['file_id', 'id', 'fileId']);
    if (pfad.isEmpty && id.isEmpty) return null;
    return CloudDatei(
      id: id.isEmpty ? pfad : id,
      pfad: pfad.isEmpty ? id : pfad,
      version: zahl(['version', 'current_version', 'file_version']),
      groesse: zahl(['size', 'bytes', 'groesse']),
      geaendert: DateTime.tryParse(text(['updated_at', 'modified', 'modified_at', 'geaendert'])),
    );
  }
}

// ------------------------------------------------------------- Verbindung

/// Zugriff auf die Datei-API der SVGCloud.
class SvgCloudVerbindung {
  SvgCloudVerbindung({
    required this.tokenSpeicher,
    Uri? server,
    this.zeitlimit = const Duration(seconds: 30),
    HttpClient Function()? clientFabrik,
  })  : server = server ?? Uri.parse('https://svgcloud.de'),
        _clientFabrik = clientFabrik ?? HttpClient.new;

  final Uri server;
  final SvgCloudTokenSpeicher tokenSpeicher;
  final Duration zeitlimit;
  final HttpClient Function() _clientFabrik;

  /// Vereinsordner-API (seit 27.11.2026 auf dem Server): Dateien werden
  /// über ihren Pfad angesprochen.
  static const String apiDateiliste = '/api/v2/club-files/files';
  static const String apiDatei = '/api/v2/club-files/file';

  /// Wie der Inhalt beim Speichern übertragen wird. Standard: multipart mit
  /// den Feldern `path`, `expected_version` und `file`; `path` und
  /// `expected_version` stehen zusätzlich in der Adresse. [SvgCloudHochladeArt.roh]
  /// schickt nur die Bytes (Angaben dann nur in der Adresse).
  SvgCloudHochladeArt hochladeArt = SvgCloudHochladeArt.multipart;

  /// Größte Datei, die der Server annimmt.
  static const int hoechstGroesse = 10 * 1024 * 1024;

  /// ZIP-Sicherungen unter `backups/` dürfen bis 25 MB groß sein.
  static const int hoechstGroesseSicherung = 25 * 1024 * 1024;

  /// Erlaubte Größe für eine Datei an diesem Pfad.
  static int hoechstGroesseFuer(String pfad) {
    final p = pfadNormal(pfad).toLowerCase();
    return p.startsWith('backups/') && p.endsWith('.zip') ? hoechstGroesseSicherung : hoechstGroesse;
  }

  /// Dateitypen, die der Server annimmt (PNG, JPG/JPEG und MD seit 27.11.2026 freigegeben).
  static const Set<String> erlaubteEndungen = {
    'json', 'csv', 'txt', 'pdf', 'xls', 'xlsx', 'zip', 'png', 'jpg', 'jpeg', 'md',
  };

  /// Pfad mit „/“, ohne führenden oder doppelten Schrägstrich.
  static String pfadNormal(String pfad) => pfad
      .replaceAll('\\', '/')
      .split('/')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty && e != '.')
      .join('/');

  Future<bool> istGekoppelt() async => ((await tokenSpeicher.lesen()) ?? '').isNotEmpty;

  /// Koppelt dieses Gerät mit dem Verbindungsschlüssel des Vereins und
  /// speichert den Geräte-Token sicher.
  Future<void> koppeln(
    String verbindungsschluessel, {
    String geraetename = '',
    String app = '',
  }) async {
    final schluessel = verbindungsschluessel.trim();
    if (schluessel.isEmpty) {
      throw SvgCloudFehler('Bitte den Verbindungsschlüssel eingeben.');
    }
    final antwort = await _json('POST', '/api/v1/connections/pair',
        mitToken: false,
        body: {
          'connection_key': schluessel,
          'device_name': geraetename.isEmpty ? Platform.localHostname : geraetename,
          'app': app,
          'platform': Platform.operatingSystem,
        });
    final token = antwort is Map
        ? (antwort['device_token'] ?? antwort['token'] ?? antwort['access_token'])?.toString()
        : null;
    if (token == null || token.isEmpty) {
      throw SvgCloudFehler('Die SVGCloud hat keinen Gerätezugang geliefert. '
          'Bitte den Verbindungsschlüssel prüfen.');
    }
    await tokenSpeicher.speichern(token);
  }

  /// Trennt dieses Gerät (löscht nur den gespeicherten Token).
  Future<void> entkoppeln() => tokenSpeicher.loeschen();

  /// Prüft Verbindung und Gerätezugang. Wirft [SvgCloudOffline] oder
  /// [SvgCloudNichtGekoppelt]; liefert die Antwort des Servers (z. B. Verein).
  Future<Object?> pruefen() => _json('POST', '/api/v1/connections/ping');

  /// Prüft, ob der gemeinsame Vereinsordner erreichbar ist. Der Server
  /// legt ihn selbst an; es wird nur die Dateiliste abgerufen.
  Future<void> ordnerEinrichten() async {
    await dateiliste();
  }

  /// Alle Dateien des gemeinsamen Vereinsbereichs.
  Future<List<CloudDatei>> dateiliste() async {
    final antwort = await _json('GET', apiDateiliste);
    final liste = antwort is List
        ? antwort
        : (antwort is Map ? (antwort['files'] ?? antwort['data'] ?? antwort['items']) : null);
    if (liste is! List) return [];
    return liste.map(CloudDatei.ausJson).whereType<CloudDatei>().toList();
  }

  /// Sucht eine Datei über ihren Pfad. null, wenn es sie noch nicht gibt.
  Future<CloudDatei?> datei(String pfad) async {
    final p = pfadNormal(pfad);
    for (final d in await dateiliste()) {
      if (d.pfad == p) return d;
    }
    return null;
  }

  /// Lädt den Inhalt einer Datei (über ihren Pfad).
  Future<List<int>> herunterladen(CloudDatei datei) => herunterladenPfad(datei.pfad);

  /// Lädt den Inhalt der Datei unter [pfad].
  Future<List<int>> herunterladenPfad(String pfad) async {
    final antwort = await _anfrage('GET', apiDatei, abfrage: {'path': pfadNormal(pfad)});
    return _inhaltAusAntwort(antwort);
  }

  /// Der Server kann den Inhalt roh oder als JSON-Hülle liefern
  /// (`content_base64` bzw. `content` + `encoding: base64`).
  static List<int> _inhaltAusAntwort(_Antwort a) {
    if (!a.istJson) return a.bytes;
    final j = a.json;
    if (j is Map && (j.containsKey('content_base64') ||
        (j.containsKey('content') && (j.containsKey('path') || j.containsKey('encoding'))))) {
      final b64 = j['content_base64'];
      if (b64 is String) return base64Decode(b64);
      final c = j['content'];
      if (c is String) {
        return '${j['encoding']}'.toLowerCase() == 'base64' ? base64Decode(c) : utf8.encode(c);
      }
    }
    return a.bytes;
  }

  /// Lädt eine Datei hoch. [erwarteteVersion] = 0 für eine neue Datei,
  /// sonst die zuletzt gelesene Version. Ist die Datei inzwischen geändert
  /// worden, wird [SvgCloudVersionKonflikt] geworfen und nichts geschrieben.
  Future<CloudDatei> hochladen(
    String pfad,
    List<int> inhalt, {
    required int erwarteteVersion,
    /// Ohne Bedeutung seit der Vereinsordner-API (Pfad genügt); bleibt für alte Aufrufe.
    String? dateiId,
  }) async {
    final p = pfadNormal(pfad);
    final name = p.split('/').last;
    final endung = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (!erlaubteEndungen.contains(endung)) {
      throw SvgCloudFehler('Dateien vom Typ „.$endung“ nimmt die SVGCloud nicht an ($name).');
    }
    final grenze0 = hoechstGroesseFuer(p);
    if (inhalt.length > grenze0) {
      throw SvgCloudFehler('„$name“ ist größer als ${grenze0 ~/ (1024 * 1024)} MB und kann nicht in die SVGCloud geladen werden.');
    }
    final abfrage = {'path': p, 'expected_version': '$erwarteteVersion'};
    final _Antwort antwort;
    if (hochladeArt == SvgCloudHochladeArt.roh) {
      antwort = await _anfrage('PUT', apiDatei,
          abfrage: abfrage, body: inhalt, contentType: 'application/octet-stream', konfliktPfad: p);
    } else {
      final grenze = 'svg${Random().nextInt(1 << 32)}${DateTime.now().microsecondsSinceEpoch}';
      final b = BytesBuilder(copy: false);
      void feld(String n, String wert) {
        b.add(utf8.encode('--$grenze\r\nContent-Disposition: form-data; name="$n"\r\n\r\n$wert\r\n'));
      }

      feld('expected_version', '$erwarteteVersion');
      feld('path', p);
      b.add(utf8.encode('--$grenze\r\nContent-Disposition: form-data; name="file"; '
          'filename="${name.replaceAll('"', '_')}"\r\n'
          'Content-Type: application/octet-stream\r\n\r\n'));
      b.add(inhalt);
      b.add(utf8.encode('\r\n--$grenze--\r\n'));
      antwort = await _anfrage('PUT', apiDatei,
          abfrage: abfrage,
          body: b.takeBytes(),
          contentType: 'multipart/form-data; boundary=$grenze',
          konfliktPfad: p);
    }
    final roh = antwort.json;
    final innen = roh is Map && roh['file'] is Map
        ? roh['file']
        : (roh is Map && roh['data'] is Map ? roh['data'] : roh);
    final datei = CloudDatei.ausJson(innen);
    if (datei != null && datei.version > 0) return datei;
    final v = innen is Map
        ? int.tryParse('${innen['version'] ?? innen['current_version'] ?? innen['new_version'] ?? ''}')
        : null;
    return CloudDatei(id: p, pfad: p, version: v ?? erwarteteVersion + 1, groesse: inhalt.length);
  }

  // ------------------------------------------------------------- intern

  Future<Object?> _json(String methode, String pfad,
      {Object? body, bool mitToken = true}) async {
    final a = await _anfrage(methode, pfad,
        body: body == null ? null : utf8.encode(jsonEncode(body)),
        contentType: body == null ? null : 'application/json',
        mitToken: mitToken);
    return a.json;
  }

  Future<_Antwort> _anfrage(
    String methode,
    String pfad, {
    List<int>? body,
    String? contentType,
    bool mitToken = true,
    String? konfliktPfad,
    Map<String, String>? abfrage,
  }) async {
    String? token;
    if (mitToken) {
      token = await tokenSpeicher.lesen();
      if (token == null || token.isEmpty) throw SvgCloudNichtGekoppelt();
    }
    final client = _clientFabrik();
    client.connectionTimeout = zeitlimit;
    try {
      final req = await client.openUrl(methode, server.resolveUri(Uri(path: pfad, queryParameters: abfrage))).timeout(zeitlimit);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (contentType != null) req.headers.set(HttpHeaders.contentTypeHeader, contentType);
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }
      final res = await req.close().timeout(zeitlimit);
      final bytes = <int>[];
      await for (final teil in res.timeout(zeitlimit)) {
        bytes.addAll(teil);
      }
      final antwort = _Antwort(res.statusCode, bytes,
          istJson: res.headers.contentType?.mimeType == 'application/json');
      if (res.statusCode >= 200 && res.statusCode < 300) return antwort;
      if (res.statusCode == 403 && mitToken && konfliktPfad != null) {
        final j = antwort.json;
        throw SvgCloudKeinSchreibrecht(konfliktPfad,
            j is Map ? (j['message'] ?? j['error'] ?? j['detail'])?.toString() : null);
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        if (!mitToken) {
          throw SvgCloudFehler('Der Verbindungsschlüssel wurde nicht angenommen.', status: res.statusCode);
        }
        throw SvgCloudNichtGekoppelt();
      }
      if (res.statusCode == 409 || res.statusCode == 412) {
        final j = antwort.json;
        int? v;
        if (j is Map) {
          final innen = j['file'] is Map ? j['file'] as Map : (j['data'] is Map ? j['data'] as Map : const {});
          v = int.tryParse('${j['current_version'] ?? j['version'] ?? innen['current_version'] ?? innen['version'] ?? ''}');
        }
        throw SvgCloudVersionKonflikt(konfliktPfad ?? pfad, v);
      }
      if (res.statusCode == 413) {
        throw SvgCloudFehler('Die Datei ist für die SVGCloud zu groß (höchstens 10 MB, Sicherungen unter backups/ 25 MB).', status: 413);
      }
      final j = antwort.json;
      final text = j is Map ? (j['message'] ?? j['error'] ?? j['detail'])?.toString() : null;
      throw SvgCloudFehler(
          text == null || text.isEmpty ? 'Die SVGCloud meldet einen Fehler (${res.statusCode}).' : text,
          status: res.statusCode);
    } on SocketException catch (e) {
      throw SvgCloudOffline(e.message);
    } on TimeoutException {
      throw SvgCloudOffline('Zeitüberschreitung');
    } on HandshakeException catch (e) {
      throw SvgCloudOffline(e.message);
    } on HttpException catch (e) {
      throw SvgCloudOffline(e.message);
    } finally {
      client.close(force: true);
    }
  }
}

/// Übertragungsart beim Speichern, siehe [SvgCloudVerbindung.hochladeArt].
enum SvgCloudHochladeArt { multipart, roh }

class _Antwort {
  _Antwort(this.status, this.bytes, {this.istJson = false});
  final int status;
  final List<int> bytes;
  final bool istJson;
  Object? get json {
    if (bytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }
}
