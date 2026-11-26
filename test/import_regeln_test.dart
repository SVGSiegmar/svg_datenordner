import 'dart:convert';

import 'package:svg_datenordner/import_regeln.dart';
import 'package:test/test.dart';

void main() {
  group('Importregeln (Bauplan 25.11.2026)', () {
    test('Zahlen: je Spalte, Einheiten, Minus vorn und hinten', () {
      expect(zahlLesen('- 23,00 €'), -23);
      expect(zahlLesen('23,00-'), -23);
      expect(zahlLesen('500,50 m²'), 500.5);
      expect(zahlLesen('235,142'), 235.142);
      expect(zahlLesen('1.234,56'), 1234.56);
      expect(zahlLesen('1 234,56 €'), 1234.56);
      expect(zahlLesen('1,234.56', ZahlenFormat.englisch), 1234.56);
      expect(zahlLesen('3,45E+08'), isNull);
      expect(zahlenFormatErkennen(['1.234,56', '12']), ZahlenFormat.deutsch);
      expect(zahlenFormatErkennen(['1,234.56', '7']), ZahlenFormat.englisch);
      expect(zahlenFormatErkennen(['1.234', '2.500']), ZahlenFormat.unklar);
      expect(zahlenSpalteMehrdeutig(['1.234', '2.500']), '1.234');
      expect(zahlenSpalteMehrdeutig(['1.234', '12,50']), isNull);
      expect(zahlenSpalteMehrdeutig(['12', '13']), isNull);
    });

    test('Datum: TT.MM.JJJJ, ISO, Excel-Zahl, nie raten', () {
      expect(datumLesen('02.01.2024'), DateTime(2024, 1, 2));
      expect(datumLesen('02.01.24'), DateTime(2024, 1, 2));
      expect(datumLesen('2024-01-02'), DateTime(2024, 1, 2));
      expect(excelDatumszahl(45293), DateTime(2024, 1, 2));
      expect(datumLesen('45293', excelZahl: true), DateTime(2024, 1, 2));
      expect(datumLesen('2016'), isNull, reason: 'ein Jahr bleibt ein Jahr');
      expect(datumLesen('03/04/2024', folge: DatumsFolge.unklar), isNull);
      expect(datumLesen('13/04/2024', folge: DatumsFolge.unklar), DateTime(2024, 4, 13));
      expect(datumsFolgeErkennen(['13/04/2024', '03/04/2024']), DatumsFolge.tagMonat);
      expect(datumsFolgeErkennen(['04/13/2024', '03/04/2024']), DatumsFolge.monatTag);
      expect(datumsFolgeErkennen(['03/04/2024']), DatumsFolge.unklar);
      expect(datumsFolgeErkennen(['03.04.2024']), DatumsFolge.tagMonat);
      expect(datumLesen('31.02.2024'), isNull);
    });

    test('Platzhalter, Gartennummer, Telefon, PLZ, Nummern, IBAN', () {
      for (final w in ['????', '-', 'keine Uhr', 'n. v.', '   ']) {
        expect(istPlatzhalter(w), isTrue, reason: w);
      }
      expect(istPlatzhalter('12'), isFalse);
      expect(gartennummerNormalisieren('Garten 01'), '1');
      expect(gartennummerNormalisieren('58 a'), '58a');
      expect(gartennummerNormalisieren('Parzelle 012B'), '12b');
      expect(gartennummerNormalisieren('Nr. 96.1'), '96.1');
      final tel = telefonNormalisieren(345123456.0);
      expect((tel.wert, tel.ergaenzt), ('0345123456', true));
      expect(telefonNormalisieren('3,45E+08').fehler, isTrue);
      expect(telefonNormalisieren('+49 345 123456').wert, '+49 345 123456');
      expect(plzNormalisieren(6258.0), '06258');
      expect(plzNormalisieren('06108'), '06108');
      expect(nummerAlsText('010272281').wert, '010272281');
      expect(nummerAlsText(10272281.0).alsZahl, isTrue);
      expect(ibanPruefen('DE89 3704 0044 0532 0130 00').gueltig, isTrue);
      expect(ibanPruefen('DE89 3704 0044 0532 0130 01').gueltig, isFalse);
      expect(ibanPruefen(8.32e19).fehler, contains('als Zahl'));
      expect(ibanPruefen('8,32E+19').fehler, contains('als Zahl'));
      expect(summenWort(['Summe']), 'Summe');
      expect(summenWort(['Übertrag']), 'Übertrag');
      expect(summenWort(['Gesamtvorstand Sitzung']), isNull);
    });

    test('CSV: Zeichensatz, Trennzeichen, mehrzeilige Felder', () {
      final w = importTextLesen(latin1.encode('Müller;Jürgen'));
      expect((w.text, w.zeichensatz), ('Müller;Jürgen', 'Windows-1252'));
      final u = importTextLesen([0xEF, 0xBB, 0xBF, ...utf8.encode('Größe')]);
      expect((u.text, u.zeichensatz), ('Größe', 'UTF-8 mit Kennung'));
      expect(importTextLesen(utf8.encode('Größe')).zeichensatz, 'UTF-8');
      expect(importTextLesen([0x80]).text, '€');

      expect(csvTrennzeichenErkennen('a;b;c\n1;2,5;3\n4;5,5;6').zeichen, ';');
      expect(csvTrennzeichenErkennen('a\tb\n1,5\t2\n3\t4').zeichen, '\t');
      // Kontoangaben über der Tabelle stören nicht
      expect(
          csvTrennzeichenErkennen('Konto;DE00\n\nDatum,Text,Betrag\n1,a,2\n3,b,4').zeichen,
          ',');
      final unklar = csvTrennzeichenErkennen('a;b,c\nd;e,f\ng;h,i');
      expect(unklar.zeichen, isNull);
      expect(unklar.kandidaten, containsAll([';', ',']));

      final felder = csvZerlegen('"A";"B ""x""";C\r\n"mehr\nzeilig";2;\r\n', ';');
      expect(felder, [
        ['A', 'B "x"', 'C'],
        ['mehr\nzeilig', '2', ''],
      ]);
    });

    test('CSV als Tabelle, Kopfzeile, Rückfrage beim Trennzeichen', () {
      final t = importTabelleAusCsv(
          latin1.encode('Liste 2026\n\nDatum;Text;Betrag\n05.02.2026;Müller;12,50\n'),
          'liste.csv');
      expect((t.trenner, t.zeichensatz, t.kopfZeilenNummer), (';', 'Windows-1252', 2));
      expect(t.kopf, ['Datum', 'Text', 'Betrag']);
      expect(t.zelle(0, 1).text, 'Müller');
      expect(() => importTabelleAusCsv(utf8.encode('a;b,c\nd;e,f\ng;h,i'), 'x.csv'),
          throwsA(isA<ImportRueckfrage>()));
    });
  });
}
