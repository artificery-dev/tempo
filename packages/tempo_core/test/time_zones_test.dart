import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';

/// Reading tzdb's zone table: the rows the player offers, and the places
/// behind them that [AppearanceMode.auto] asks the sun about.
void main() {
  // Real rows, tabs and all, out of /usr/share/zoneinfo/zone1970.tab.
  const table = '''
# tzdb timezone descriptions
#
#codes\tcoordinates\tTZ\tcomments
AD\t+4230+00131\tEurope/Andorra
AE,OM,RE,SC,TF\t+2518+05518\tAsia/Dubai\tCrozet
AQ\t-6617+11031\tAntarctica/Casey\tCasey
US\t+404251-0740023\tAmerica/New_York\teastern
US\t+415100-0873900\tAmerica/Chicago\tCentral (most areas)
AU\t-3352+15113\tAustralia/Sydney\tNew South Wales (most areas)
''';

  group('parsing', () {
    test('a row becomes a zone with a place behind it', () {
      final zones = TimeZones.parse(table);
      final andorra = zones.firstWhere((z) => z.id == 'Europe/Andorra');
      // +4230+00131 is 42 degrees 30 minutes north, 1 degree 31 east.
      expect(andorra.place.latitude, closeTo(42.5, 0.001));
      expect(andorra.place.longitude, closeTo(1.5167, 0.001));
      expect(andorra.comment, isNull);
    });

    test('the longer form carries seconds too', () {
      final zones = TimeZones.parse(table);
      final newYork = zones.firstWhere((z) => z.id == 'America/New_York');
      // +404251-0740023: 40 42' 51" north, 74 00' 23" west.
      expect(newYork.place.latitude, closeTo(40.7142, 0.001));
      expect(newYork.place.longitude, closeTo(-74.0064, 0.001));
    });

    test('south and west come out negative', () {
      final zones = TimeZones.parse(table);
      final casey = zones.firstWhere((z) => z.id == 'Antarctica/Casey');
      expect(casey.place.latitude, closeTo(-66.2833, 0.001));
      expect(casey.place.longitude, closeTo(110.5167, 0.001));
      expect(casey.comment, 'Casey');
    });

    test('comments and blank lines are not zones', () {
      final zones = TimeZones.parse(table);
      expect(zones.map((z) => z.id), hasLength(6));
      expect(zones.map((z) => z.id), isNot(contains(startsWith('#'))));
    });

    test('a row with unreadable coordinates is dropped, not guessed at', () {
      final zones = TimeZones.parse('XX\tnonsense\tNowhere/Special\n$table');
      expect(zones.map((z) => z.id), isNot(contains('Nowhere/Special')));
      expect(zones, hasLength(6));
    });

    test('zones come back in the order the picker shows them', () {
      final zones = TimeZones.parse(table);
      expect(zones.map((z) => z.id).toList(), [
        'America/Chicago',
        'America/New_York',
        'Antarctica/Casey',
        'Asia/Dubai',
        'Australia/Sydney',
        'Europe/Andorra',
      ]);
    });
  });

  group('how a zone reads', () {
    test('the area leads and the place follows, as words', () {
      final zones = TimeZones.parse(table);
      final newYork = zones.firstWhere((z) => z.id == 'America/New_York');
      expect(newYork.area, 'America');
      expect(newYork.location, 'New York');
      expect(newYork.label, 'New York - eastern');
    });

    test('a deeper name keeps its parts', () {
      final zones = TimeZones.parse(
        'US\t+411745-0863730\tAmerica/Indiana/Knox\tCentral - IN (Starke)\n',
      );
      expect(zones.single.area, 'America');
      expect(zones.single.location, 'Indiana, Knox');
    });
  });

  group('coordinates', () {
    test('a field of the wrong width is no place at all', () {
      expect(TimeZones.parseCoordinates('+4230'), isNull);
      expect(TimeZones.parseCoordinates(''), isNull);
      expect(TimeZones.parseCoordinates('4230+00131'), isNull);
    });

    test('a latitude past the pole is refused', () {
      // +9930 is not a latitude; the table should never hold one, and a
      // place that is not a place must not reach the sun calculation.
      expect(TimeZones.parseCoordinates('+9930+00131'), isNull);
    });
  });

  group('the machine\'s own table', () {
    test('UTC is a clock rather than a place', () {
      expect(TimeZones.placeOf(TimeZones.utc), isNull);
      expect(TimeZones.placeOf(null), isNull);
    });

    test('a zone this machine does not have has no place either', () {
      expect(TimeZones.placeOf('Nowhere/Special'), isNull);
    });

    test('the areas are the parts before the slashes, in order', () {
      // Whatever this machine's zoneinfo holds - a build host without one
      // gets an empty list, which is a state the picker draws.
      final areas = TimeZones.areas;
      expect(areas, equals(List.of(areas)..sort()));
      for (final area in areas) {
        expect(area, isNot(contains('/')));
        expect(TimeZones.inArea(area), isNotEmpty);
      }
    });
  });
}
