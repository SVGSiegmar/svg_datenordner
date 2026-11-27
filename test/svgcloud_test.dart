import 'dart:convert';
import 'dart:io';

import 'package:svg_datenordner/svg_datenordner.dart';
import 'package:test/test.dart';

/// Kleiner Ersatz-Server mit dem Verhalten der SVGCloud-Datei-API.
class ErsatzServer {
  late HttpServer server;
  final dateien = <String, Map<String, Object>>{}; // pfad -> {version, bytes}
  String token = 'geraet-123';
  bool aus = false;
  bool alsHuelle = false;

  Uri get adresse => Uri.parse('http://${server.address.host}:${server.port}');

  Future<void> starten() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_bearbeiten);
  }

  Future<void> stoppen() => server.close(force: true);

  Future<void> _bearbeiten(HttpRequest req) async {
    final res = req.response;
    Future<void> json(int status, Object? body) async {
      res.statusCode = status;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(body));
      await res.close();
    }

    final pfad = req.uri.path;
    if (pfad == '/api/v1/connections/pair') {
      final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
      if (body['connection_key'] != 'SCHLUESSEL') return json(401, {'message': 'falsch'});
      return json(200, {'device_token': token});
    }
    if (req.headers.value(HttpHeaders.authorizationHeader) != 'Bearer $token') {
      return json(401, {'message': 'nicht gekoppelt'});
    }
    if (pfad == '/api/v1/connections/ping') return json(200, {'ok': true});
    if (pfad == '/api/v2/club-files/files' && req.method == 'GET') {
      return json(200, {
        'files': [
          for (final e in dateien.entries)
            {'path': e.key, 'version': e.value['version'], 'size': (e.value['bytes'] as List).length}
        ]
      });
    }
    if (pfad == '/api/v2/club-files/file') {
      final dateiPfad = req.uri.queryParameters['path'] ?? '';
      if (req.method == 'GET') {
        final d = dateien[dateiPfad];
        if (d == null) return json(404, {'message': 'fehlt'});
        if (alsHuelle) {
          return json(200, {'path': dateiPfad, 'version': d['version'], 'content_base64': base64Encode(d['bytes'] as List<int>)});
        }
        res.headers.contentType = ContentType.binary;
        res.add(d['bytes'] as List<int>);
        return res.close();
      }
      if (req.method == 'PUT') {
        final roh = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        final text = latin1.decode(roh);
        final erwartet = int.parse(RegExp(r'name="expected_version"\r\n\r\n(\d+)').firstMatch(text)!.group(1)!);
        if (req.uri.queryParameters['expected_version'] != '$erwartet') return json(400, {'message': 'expected_version fehlt in der Adresse'});
        final pfadFeld = RegExp(r'name="path"\r\n\r\n([^\r]*)').firstMatch(text)!.group(1)!;
        if (pfadFeld != dateiPfad) return json(400, {'message': 'path passt nicht'});
        final start = text.indexOf('\r\n\r\n', text.indexOf('name="file"')) + 4;
        final ende = text.lastIndexOf('\r\n--');
        final inhalt = roh.sublist(start, ende);
        final aktuell = (dateien[pfadFeld]?['version'] as int?) ?? 0;
        if (erwartet != aktuell) return json(409, {'error': 'version_conflict', 'current_version': aktuell});
        dateien[pfadFeld] = {'version': aktuell + 1, 'bytes': inhalt};
        return json(200, {'path': pfadFeld, 'version': aktuell + 1});
      }
    }
    return json(404, {'message': 'unbekannt'});
  }
}

void main() {
  late ErsatzServer s;
  late Directory tmp;

  setUp(() async {
    s = ErsatzServer();
    await s.starten();
    tmp = await Directory.systemTemp.createTemp('svgcloud_test');
  });
  tearDown(() async {
    await s.stoppen();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  SvgCloudVerbindung verbindung([SvgCloudTokenSpeicher? t]) =>
      SvgCloudVerbindung(tokenSpeicher: t ?? SvgCloudTokenImSpeicher(), server: s.adresse);

  test('koppeln speichert den Token, falscher Schlüssel wird abgelehnt', () async {
    final t = SvgCloudTokenImSpeicher();
    final v = verbindung(t);
    expect(await v.istGekoppelt(), isFalse);
    await expectLater(v.koppeln('FALSCH'), throwsA(isA<SvgCloudFehler>()));
    await v.koppeln('SCHLUESSEL', geraetename: 'Testrechner', app: 'Test');
    expect(await t.lesen(), 'geraet-123');
    await v.pruefen();
  });

  test('ohne Kopplung: verständlicher Fehler', () async {
    await expectLater(verbindung().dateiliste(), throwsA(isA<SvgCloudNichtGekoppelt>()));
  });

  test('neu anlegen, lesen, ändern; Konflikt zweier Geräte wird erkannt', () async {
    final a = CloudGemeinsameDaten(verbindung(SvgCloudTokenImSpeicher('geraet-123')),
        pfad: 'daten/app_daten.json', zwischenspeicher: Directory('${tmp.path}/a'));
    final b = CloudGemeinsameDaten(verbindung(SvgCloudTokenImSpeicher('geraet-123')),
        pfad: 'daten/app_daten.json', zwischenspeicher: Directory('${tmp.path}/b'));

    expect(await a.lesen(), isNull);
    final erster = await a.aendern((d) => d['stammdaten'] = {'vereinsname': 'KGV Test'}, neuAnlegenErlaubt: true);
    expect(erster.pruefsumme, 'v1');

    final gelesenB = await b.lesen();
    expect(gelesenB!.daten['stammdaten']['vereinsname'], 'KGV Test');

    // A speichert, B hat noch v1 im Kopf
    await a.aendern((d) => d['x'] = 1);
    await expectLater(
        b.aendern((d) => d['y'] = 2, erwartetePruefsumme: gelesenB.pruefsumme),
        throwsA(isA<DatenWurdenGeaendert>()));
    // Ohne erwartete Prüfsumme: neu lesen und einfügen – beide Änderungen bleiben
    final ok = await b.aendern((d) => d['y'] = 2);
    expect(ok.daten['x'], 1);
    expect(ok.daten['y'], 2);
    expect(ok.pruefsumme, 'v3');
  });

  test('offline: lesen aus dem Zwischenspeicher, Änderung wird nachgeholt', () async {
    final v = verbindung(SvgCloudTokenImSpeicher('geraet-123'));
    final c = CloudGemeinsameDaten(v, pfad: 'daten/kassenbuch.json', zwischenspeicher: Directory('${tmp.path}/c'));
    await c.aendern((d) => d['buchungen'] = [1], neuAnlegenErlaubt: true);
    await s.stoppen(); // Netz weg
    final offline = await c.lesen();
    expect(c.offline, isTrue);
    expect(offline!.daten['buchungen'], [1]);
    await expectLater(c.aendern((d) => (d['buchungen'] as List).add(2)), throwsA(isA<SvgCloudOffline>()));
    expect(await c.hatAusstehendes(), isTrue);

    // Netz wieder da (neuer Server mit demselben Bestand)
    final alt = s.dateien;
    s = ErsatzServer()..dateien.addAll(alt);
    await s.starten();
    final c2 = CloudGemeinsameDaten(verbindung(SvgCloudTokenImSpeicher('geraet-123')),
        pfad: 'daten/kassenbuch.json', zwischenspeicher: Directory('${tmp.path}/c'));
    final nach = await c2.nachholen();
    expect(nach!.daten['buchungen'], [1, 2]);
    expect(await c2.hatAusstehendes(), isFalse);
  });

  test('Dokumente werden nie überschrieben, unerlaubte Typen abgelehnt', () async {
    final v = verbindung(SvgCloudTokenImSpeicher('geraet-123'));
    final d1 = await cloudDokumentAblegen(v, 'dokumente/Begehung/Parzelle 12/Begehung_12.pdf', [1, 2, 3]);
    final d2 = await cloudDokumentAblegen(v, 'dokumente/Begehung/Parzelle 12/Begehung_12.pdf', [4, 5]);
    expect(d1.pfad, 'dokumente/Begehung/Parzelle 12/Begehung_12.pdf');
    expect(d2.pfad, 'dokumente/Begehung/Parzelle 12/Begehung_12 (2).pdf');
    await expectLater(v.hochladen('locks/schreibsperre.lock', [1], erwarteteVersion: 0),
        throwsA(isA<SvgCloudFehler>()));
  });

  test('Vereinsordner-API: JSON-Hülle beim Lesen, Konflikt mit current_version', () async {
    s.alsHuelle = true;
    final v = verbindung(SvgCloudTokenImSpeicher('geraet-123'));
    final d1 = await v.hochladen('dokumente/Begehung/Parzelle 7/Protokoll.txt', utf8.encode('Hallo'), erwarteteVersion: 0);
    expect(d1.version, 1);
    expect(utf8.decode(await v.herunterladenPfad('dokumente/Begehung/Parzelle 7/Protokoll.txt')), 'Hallo');
    try {
      await v.hochladen('dokumente/Begehung/Parzelle 7/Protokoll.txt', utf8.encode('alt'), erwarteteVersion: 0);
      fail('Konflikt erwartet');
    } on SvgCloudVersionKonflikt catch (k) {
      expect(k.aktuelleVersion, 1);
    }
  });
}
