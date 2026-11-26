# svg_datenordner

Gemeinsamer Datenordner für Kleingartenverwaltung, Gartenvergabe, Gartenbegehung
und Kassenbuch. Version 0.2.0 – Stand 19.11.2026.

Das Paket ist reines Dart (kein Flutter nötig) und hat nur eine Abhängigkeit: `crypto`.

## Was es kann

| Baustein | Aufgabe |
| --- | --- |
| `DatenordnerEinstellung` | Speicherart pro Gerät: `lokal`, `ordner` (NAS, FRITZ!Box, OneDrive, iCloud …), `svgCloud` (später). Wird bei der Einrichtung abgefragt und lokal gespeichert, nie in der gemeinsamen Datei. |
| `Datenordner` | Alle Pfade im Ordner: `daten/app_daten.json`, `locks/`, `rechnungen/` und die Dokumentenordner der Parzellen `dokumente/<Kategorie>/Parzelle <Nr>/` – exakt wie in der Kleingartenverwaltung. `freieDatei` liefert einen Dateinamen, der nichts überschreibt. |
| `Schreibsperre` | Kurze Sperre nur während des Speicherns (`locks/schreibsperre.json`). Verwaist nach 2 Minuten. |
| `GemeinsameDaten` | Lesen, Prüfsumme (SHA-256 wie in der Kleingartenverwaltung) und **sicheres Ändern**: Sperre → frisch lesen → ändern → schreiben → Sperre frei. |
| `KgvDaten` | Bequemer Zugriff auf Verein, Parzellen und Mitglieder im Format der Kleingartenverwaltung; neues Mitglied anlegen; Vorpächter austragen; Datum TT.MM.JJJJ. |

Bei „lokal“ übergibt die App ihren Dokumentenordner als Wurzel. Dann gilt derselbe
Aufbau auf dem Gerät, und der Code ist für beide Fälle gleich.

## Neu in 0.2.0: eigene Datei für das Kassenbuch

Das Kassenbuch speichert in `daten/kassenbuch.json` (neben `app_daten.json`),
mit derselben Schreibsperre. So wachsen Buchungen und Änderungsprotokoll nicht in
die gemeinsame Datei der anderen Apps hinein; lesen können diese sie trotzdem.

```dart
final kb = GemeinsameDaten(ordner,
    app: 'Kassenbuch', benutzer: benutzer, datei: ordner.kassenbuchDatei);
final stand = await kb.lesen();
await kb.aendern((d) { /* … */ },
    neuAnlegenErlaubt: true, erwartetePruefsumme: stand?.pruefsumme ?? '');
```

Mit `erwartetePruefsumme` schreibt `aendern` nur, wenn die Datei seit dem letzten
Lesen unverändert ist – sonst kommt `DatenWurdenGeaendert` und nichts wird
überschrieben. Ohne den Parameter verhält sich alles wie in 0.1.0.

## Neu in 0.5.0: verschlüsselte Sicherungen (`SvgSicherung`)

Beschluss: Sicherungen aller Verbands-Apps werden echt verschlüsselt.
`SvgSicherung` ist das gemeinsame Verfahren – einmal gebaut, für alle vier Apps:

- Schlüssel aus dem Passwort: PBKDF2-HMAC-SHA256, zufälliges Salz,
  200.000 Durchläufe (Zahl steht in der Datei und kann später steigen)
- Inhalt gzip-komprimiert, verschlüsselt mit AES-256-GCM (mit Prüfsumme:
  falsches Passwort oder veränderte Datei werden erkannt)
- Datei = JSON mit lesbarem Kopf (`format: svg-sicherung`, App, Datum);
  das Passwort wird nirgends gespeichert

```dart
final datei = await SvgSicherung.verschluesseln(utf8.encode(json), passwort,
    app: 'Kassenbuch');
final inhalt = await SvgSicherung.entschluesseln(datei, passwort);
```

Die bisherigen Sicherungen mit XOR-Verfahren sind **keine** echte
Verschlüsselung; die Apps lesen sie weiter ein, schreiben aber nur noch das
neue Format.

## Die eine Regel für alle Apps

**Neu lesen – Änderung einfügen – schreiben.** Eine App schreibt nie ihren ganzen
Datenstand zurück, sondern holt sich unter der Sperre den aktuellen Stand und ändert
nur das, was sie ändern will. Alles andere (auch Bereiche, die sie gar nicht kennt,
wie Rechnungen oder Benutzer) bleibt unverändert.

## Schritt 1: Tests auf dem Mac ausführen

```bash
cd ~/X-Code-Projekte/Pakete/svg_datenordner
dart pub get
dart test
```

Alle Tests müssen grün sein. Sie prüfen u. a., dass zwei Apps gleichzeitig
speichern und trotzdem keine Änderung verloren geht.

## Schritt 2: Als eigenes GitHub-Repository anlegen

Weil die Apps über GitHub gebaut werden, funktioniert ein lokaler Pfad
(`path: ../..`) dort nicht. Deshalb das Paket als eigenes Repository anlegen,
z. B. `svg_datenordner`, und mit einer Versionsmarke versehen:

```bash
cd ~/X-Code-Projekte/Pakete/svg_datenordner
git init && git add . && git commit -m "svg_datenordner 0.1.0"
git tag v0.1.0
# Repository auf GitHub anlegen, dann:
git remote add origin https://github.com/<Konto>/svg_datenordner.git
git push -u origin main --tags
```

Ist das Repository privat, braucht der GitHub-Build der Apps Lesezugriff darauf
(z. B. über einen Deploy-Key oder ein Token in den Actions-Secrets).

## Schritt 3: In einer App einbinden

In der `pubspec.yaml` der App:

```yaml
dependencies:
  svg_datenordner:
    git:
      url: https://github.com/<Konto>/svg_datenordner.git
      ref: v0.1.0
```

Danach `flutter pub get`.

## Beispiel Gartenvergabe: Daten übernehmen

```dart
import 'package:svg_datenordner/svg_datenordner.dart';

final ordner = Datenordner(einstellung.pfad);
final gd = GemeinsameDaten(ordner, app: 'Gartenvergabe', benutzer: benutzername);

final stand = await gd.lesen();          // null = noch keine Daten im Ordner
if (stand != null) {
  final kgv = KgvDaten(stand.daten);
  settings.clubName = kgv.vereinsname;
  settings.clubAddress = kgv.vereinsanschrift;
  settings.place = kgv.vereinsort;
  settings.chairperson = kgv.vorsitz;

  final freieGaerten = kgv.parzellennummern(nurLeerstand: true);
  final p = kgv.parzelle(gewaehlteNummer);
  assignment.gardenArea = (p?['pachtflaeche'] ?? '').toString();
  assignment.waterMeterNumber = (p?['wasserZaehler'] ?? '').toString();
  assignment.electricityMeterNumber = (p?['stromZaehler'] ?? '').toString();

  final vorpaechter = kgv.paechterVon(gewaehlteNummer);   // für Verkäufer der Laube
}
```

## Beispiel Gartenvergabe: neuen Pächter übergeben

```dart
await gd.aendern((daten) {
  final kgv = KgvDaten(daten);
  final neu = kgv.neuesMitglied({
    'vorname': a.firstName,
    'name': a.lastName,
    'adresse': a.street,
    'plz': a.postalCode,
    'ort': a.city,
    'telefon': a.phone,
    'email': a.email,
    'geburtstag': a.birthDate == null ? '' : KgvDaten.datumKgv(a.birthDate!),
    'garten': a.gardenNumber,
    'eintrittsdatum': KgvDaten.datumKgv(a.takeoverDate!),
  });
  kgv.bisherigePaechterAustragen(
    a.gardenNumber,
    a.takeoverDate!,
    ausser: {neu['id'] as int},
  );
});
```

Kann die Sperre nicht geholt werden, kommt `SchreibsperreBelegt`. Deren
`beschreibung` (z. B. „Kleingartenverwaltung (Siegmar an MacBook) speichert gerade.“)
kann direkt angezeigt werden.

## Beispiel Gartenbegehung: PDF bei der Parzelle ablegen

PDFs und Fotos der Begehung entstehen nur in der Gartenbegehung. Jede Datei
bekommt einen eigenen Namen, nichts wird überschrieben – deshalb ist dafür
**keine Schreibsperre nötig**. Die Kleingartenverwaltung zeigt die Kategorie
„Begehung“ automatisch bei den Dokumenten der Parzelle an.

```dart
final kgv = KgvDaten((await gd.lesen())!.daten);
// Schreibweise aus app_daten.json übernehmen, damit der Ordner exakt passt
final parzelle = (kgv.parzelle(gartennummer)?['parzelle'] ?? gartennummer).toString();

final zielOrdner = ordner.dokumentOrdner('Begehung', parzelle);
final datum = begehungsDatum.toIso8601String().substring(0, 10); // 2026-11-17
final ziel = await Datenordner.freieDatei(zielOrdner, 'Begehung_${parzelle}_$datum.pdf');
await ziel.writeAsBytes(pdfBytes, flush: true);
```

Ergebnis z. B.: `dokumente/Begehung/Parzelle 12A/Begehung_12A_2026-11-17.pdf`

**Keine Datumsordner:** Die Kleingartenverwaltung zeigt beim Pächter nur Dateien,
die direkt im Ordner `Parzelle <Nr>` liegen. Das Datum gehört in den Dateinamen.

Dasselbe gilt für die Gartenvergabe mit der Kategorie „Pachtvertrag“. Auch extern
erstellte Pachtverträge landen so an derselben Stelle.

## Was die Kleingartenverwaltung noch braucht

Die Kleingartenverwaltung erkennt fremde Änderungen schon heute über die Prüfsumme
und zeigt nach spätestens 30 Sekunden „Jetzt neu laden“. Zwei Dinge fehlen:

1. **Speichern unter der Schreibsperre.** In `speichereAlleDatenJetzt` die Prüfung
   der Prüfsumme und das Schreiben zwischen `Schreibsperre.erwerben()` und
   `freigeben()` legen. Sonst kann die Gartenvergabe genau zwischen Prüfen und
   Schreiben speichern.
2. **„Meine Fassung speichern“ entschärfen.** Dieser Knopf im Konfliktdialog schreibt
   den ganzen eigenen Stand und löscht damit z. B. einen Pächter, den die
   Gartenvergabe gerade angelegt hat. Besser: nur „Neu laden“ anbieten, oder die
   eigene Änderung nach dem Neuladen erneut anwenden.

## Grenzen

- **NAS / FRITZ!Box:** Sperre und Prüfsumme greifen sofort, mehrere Personen sind möglich.
- **OneDrive, iCloud, MagentaCloud:** Diese Ordner gleichen sich mit Verzögerung ab.
  Die Sperre kommt beim anderen Rechner evtl. zu spät an, es können Konfliktkopien
  entstehen. Empfehlung: dort jeweils nur eine Person zur Zeit.
- **iPad / Android:** kein frei einstellbarer Pfad. Ein Ordner muss einmal über die
  Dateien-App bzw. die Android-Ordnerauswahl freigegeben werden; SMB-Freigaben sind
  dort unzuverlässig.

## 0.3.0 (22.11.2026)

- Ordner `austausch/` für den Datenaustausch Kleingartenverwaltung ↔ Kassenbuch,
  wird von `grundordnerAnlegen()` mit angelegt.
- `austauschOrdner`, `verwaltungForderungenDatei`
  (`austausch/verwaltung_forderungen.json`, schreibt die Verwaltung),
  `kassenbuchZahlungenDatei` (`austausch/kassenbuch_zahlungen.json`, schreibt das
  Kassenbuch).
- `gartenvergabeDatei` (`daten/gartenvergabe.json`).
- Abwärtskompatibel zu 0.1.0 und 0.2.0.

## 0.6.0 (26.11.2026): Sicherung, Vereinskennung und Importregeln in einer Fassung

Fasst die beiden Stände zusammen, die parallel als „0.5.0“ entstanden sind:
`SvgSicherung` (Zweig `sicherung-0.5.0`, vom Kassenbuch genutzt) und die
Vereinskennung (Tag `0.5.0`). Dazu kommen die **Importregeln**.

- `SvgSicherung` – verschlüsselte Sicherung (AES-256-GCM, Schlüssel aus dem
  Passwort mit PBKDF2, Datei `.svgsicherung`). Siehe Abschnitt zur Sicherung.
- `Vereinskennung` / `VereinsPruefung` – unverändert wie 0.5.0.
- **Importregeln** (Bauplan „Importregeln“ vom 25.11.2026): Zeichensatz
  (UTF-8/Windows-1252), Trennzeichen mit Rückfrage, CSV mit mehrzeiligen
  Feldern, Zahlen je Spalte (deutsch/englisch, Einheiten, Minus hinten),
  Datum (TT.MM.JJJJ, ISO, Excel-Zahl, nie raten), Platzhalter, Gartennummer,
  Telefon, PLZ, Nummern als Text, IBAN mit Prüfziffer, Summenzeilen,
  Tabellenmodell `ImportTabelle` und `importTabelleAusCsv`.
  Excel-Dateien liest jede App selbst (Paket „excel“) und füllt damit eine
  `ImportTabelle`; Vorlage dafür: `lib/core/excel_hilfe.dart` im Kassenbuch
  (`importTabelleAusExcel`: Formelergebnisse, Kommentare, Ausgeblendetes).

Einbinden ohne Präfix, wenn das Paket sonst mit `as svg` importiert ist:

```dart
import 'package:svg_datenordner/import_regeln.dart';
```

## 0.5.0 (26.11.2026): Vereinskennung

Schützt davor, Daten zweier Vereine oder Test- und Echtdaten (Musteranlage) zu mischen.

- `daten/verein.json` mit Vereinsname, fester Kennung, Datum und App. Wird einmal angelegt und nie überschrieben.
- `VereinsPruefung.pruefen(ordner, eigenerVereinsname: …, eigeneKennung: …)` liefert `ordnerLeer`, `gleicherVerein`, `andererVerein` oder `unklar`, dazu `darfWeiter` und einen fertigen Satz `text` für die Meldung.
- Ordner ohne `verein.json` (vor 0.5.0): Der Vereinsname wird aus `app_daten.json` gelesen und verglichen (ohne Groß-/Kleinschreibung, Satzzeichen und „e. V.“).
- `VereinsPruefung.anlegen(ordner, vereinsname: …, app: …)` legt die Kennung an, falls sie fehlt.

Einbau in jeder App beim „Ordner auswählen“, **bevor** etwas geladen, zusammengeführt oder geschrieben wird:

```dart
final ordner = Datenordner(pfad);
final pruefung = await VereinsPruefung.pruefen(ordner,
    eigenerVereinsname: vereinsname, eigeneKennung: gemerkteKennung);
if (pruefung.status == VereinsStatus.andererVerein) { meldung(pruefung.text); return; }
if (pruefung.status == VereinsStatus.unklar && !await rueckfrage(pruefung.text)) return;
final kennung = await VereinsPruefung.anlegen(ordner, vereinsname: vereinsname, app: 'Kleingartenverwaltung');
gemerkteKennung = kennung.kennung; // je Gerät in den Einstellungen merken
```

Eine App ohne eigenen Vereinsnamen (neue Installation) übernimmt Name und Kennung aus dem Ordner.

## 0.4.0 (22.11.2026)

- `OrdnerUmzug(alt, neu)`: nimmt beim Wechsel des Datenordners den Inhalt des
  bisherigen Ordners mit – ohne Terminal oder Finder.
  - `pruefen()` liefert einen `UmzugBestand` (Datendateien, Rechnungen, Dokumente,
    weitere Dateien, `schonImZiel`, `beschreibung` für die Rückfrage).
  - `ausfuehren(fortschritt: …)` kopiert wie `rsync --ignore-existing`: Ordner
    zusammenführen, vorhandene Dateien nie überschreiben, `locks/`, `temp/`,
    Papierkorb, `*.lock` und Hilfsdateien auslassen; der alte Ordner bleibt.
- Empfohlener Ablauf in jeder App beim „Ordner auswählen“: `pruefen()`, bei
  `!leer` fragen („Im bisherigen Ordner liegen … – in den neuen Ordner
  mitnehmen?“), dann `ausfuehren()` und das Ergebnis anzeigen.
