import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';

/// Sunrise and sunset, checked against NOAA's own solar calculator.
///
/// The expectations below were produced by the NOAA spreadsheet algorithm,
/// which is a different formulation from the one [Solar] implements - it
/// works through the equation of time rather than the hour angle directly -
/// so agreement is evidence about the answer rather than about the
/// transcription. Every one of them lands within a quarter of a minute; the
/// tolerance here is a minute, which is far finer than a backlight needs.
void main() {
  const minute = Duration(minutes: 1);

  void expectNear(DateTime? actual, String expected, {required String what}) {
    expect(actual, isNotNull, reason: '$what: expected a time, got none');
    final wanted = DateTime.parse(expected);
    expect(
      actual!.difference(wanted).abs(),
      lessThan(minute),
      reason:
          '$what: expected about $expected, got ${actual.toIso8601String()}',
    );
  }

  /// Noon UTC on a date, which is only ever used to say which day is meant.
  DateTime noonOn(String date) => DateTime.parse('${date}T12:00:00Z');

  group('the sun at a place on a day', () {
    const places = {
      'equator': SolarPlace(latitude: 0, longitude: 0),
      'london': SolarPlace(latitude: 51.5074, longitude: -0.1278),
      'newYork': SolarPlace(latitude: 40.7128, longitude: -74.0060),
      'sydney': SolarPlace(latitude: -33.8688, longitude: 151.2093),
      'reykjavik': SolarPlace(latitude: 64.1466, longitude: -21.9426),
      'quito': SolarPlace(latitude: -0.1807, longitude: -78.4678),
    };

    test('the equator on the equinox: six to six, near enough', () {
      final day = Solar.dayAt(places['equator']!, noonOn('2026-03-20'));
      expectNear(day.sunrise, '2026-03-20T06:04:06Z', what: 'equator sunrise');
      expectNear(day.sunset, '2026-03-20T18:10:45Z', what: 'equator sunset');
    });

    test('London on the longest day', () {
      final day = Solar.dayAt(places['london']!, noonOn('2026-06-21'));
      expectNear(day.sunrise, '2026-06-21T03:43:09Z', what: 'London sunrise');
      expectNear(day.sunset, '2026-06-21T20:21:30Z', what: 'London sunset');
    });

    test(
      'a place west of Greenwich has its noon later in UTC, not earlier',
      () {
        final day = Solar.dayAt(places['newYork']!, noonOn('2026-06-21'));
        expectNear(
          day.sunrise,
          '2026-06-21T09:25:02Z',
          what: 'New York sunrise',
        );
        expectNear(day.sunset, '2026-06-22T00:30:39Z', what: 'New York sunset');
      },
    );

    test('a place east of it has its noon earlier', () {
      final day = Solar.dayAt(places['sydney']!, noonOn('2026-06-21'));
      expectNear(day.sunrise, '2026-06-20T21:00:05Z', what: 'Sydney sunrise');
      expectNear(day.sunset, '2026-06-21T06:53:52Z', what: 'Sydney sunset');
    });

    test('the far north in midsummer: a night barely worth the name', () {
      final day = Solar.dayAt(places['reykjavik']!, noonOn('2026-06-21'));
      expectNear(day.sunrise, '2026-06-21T02:55:13Z', what: 'sunrise');
      expectNear(day.sunset, '2026-06-22T00:03:57Z', what: 'sunset');
    });

    test('the equator in October', () {
      final day = Solar.dayAt(places['quito']!, noonOn('2026-10-15'));
      expectNear(day.sunrise, '2026-10-15T10:56:08Z', what: 'Quito sunrise');
      expectNear(day.sunset, '2026-10-15T23:03:06Z', what: 'Quito sunset');
    });
  });

  group('above the arctic circle the sun does not cross at all', () {
    const svalbard = SolarPlace(latitude: 78.2232, longitude: 15.6267);

    test('midsummer is one long day', () {
      final day = Solar.dayAt(svalbard, noonOn('2026-06-21'));
      expect(day.sunrise, isNull);
      expect(day.sunset, isNull);
      expect(day.isPolar, isTrue);
      expect(day.daylight, isTrue);
      expect(Solar.isDaylight(svalbard, noonOn('2026-06-21')), isTrue);
      // And at what would be the dead of night, just as much.
      expect(
        Solar.isDaylight(svalbard, DateTime.parse('2026-06-21T01:00:00Z')),
        isTrue,
      );
    });

    test('midwinter is one long night', () {
      final day = Solar.dayAt(svalbard, noonOn('2026-12-21'));
      expect(day.isPolar, isTrue);
      expect(day.daylight, isFalse);
      expect(Solar.isDaylight(svalbard, noonOn('2026-12-21')), isFalse);
    });
  });

  group('whether the sun is up', () {
    const london = SolarPlace(latitude: 51.5074, longitude: -0.1278);

    // London on the longest day: up at 03:43 UTC, down at 20:21 UTC.
    test('the afternoon belongs to its own day, not to tomorrow', () {
      // The bug this guards: taking the *next* solar noon rather than the
      // nearest one puts one o'clock before tomorrow's sunrise, and the
      // player goes dark in the middle of the afternoon.
      expect(
        Solar.isDaylight(london, DateTime.parse('2026-06-21T13:00:00Z')),
        isTrue,
      );
      expect(
        Solar.isDaylight(london, DateTime.parse('2026-06-21T17:00:00Z')),
        isTrue,
      );
    });

    test('before sunrise and after sunset it is not', () {
      expect(
        Solar.isDaylight(london, DateTime.parse('2026-06-21T02:00:00Z')),
        isFalse,
      );
      expect(
        Solar.isDaylight(london, DateTime.parse('2026-06-21T22:00:00Z')),
        isFalse,
      );
    });

    test('right through a winter day, hour by hour', () {
      // Sunrise about 08:04 UTC, sunset about 15:53 UTC.
      final up = <int>[];
      for (var hour = 0; hour < 24; hour++) {
        final at = DateTime.utc(2026, 12, 21, hour);
        if (Solar.isDaylight(london, at)) up.add(hour);
      }
      expect(up, [9, 10, 11, 12, 13, 14, 15]);
    });
  });

  group('the next change', () {
    const london = SolarPlace(latitude: 51.5074, longitude: -0.1278);

    test('before dawn it is the sunrise; after it, the sunset', () {
      final beforeDawn = DateTime.parse('2026-06-21T02:00:00Z');
      expectNear(
        Solar.nextChange(london, beforeDawn),
        '2026-06-21T03:43:09Z',
        what: 'next change before dawn',
      );

      final afternoon = DateTime.parse('2026-06-21T13:00:00Z');
      expectNear(
        Solar.nextChange(london, afternoon),
        '2026-06-21T20:21:30Z',
        what: 'next change in the afternoon',
      );
    });

    test('after sunset it is tomorrow morning', () {
      final night = DateTime.parse('2026-06-21T22:00:00Z');
      final next = Solar.nextChange(london, night);
      expect(next, isNotNull);
      expect(next!.isAfter(night), isTrue);
      // Tomorrow's sunrise, a few minutes later than today's.
      expect(next.day, 22);
      expect(next.hour, 3);
    });

    test('a polar summer has none to give, and says so', () {
      const svalbard = SolarPlace(latitude: 78.2232, longitude: 15.6267);
      expect(Solar.nextChange(svalbard, noonOn('2026-06-21')), isNull);
    });
  });
}
