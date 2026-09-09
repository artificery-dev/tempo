import 'dart:math' as math;

/// Where on the earth the player thinks it is, for the sun's sake.
///
/// Degrees, north and east positive - the convention every map and every
/// phone uses, so a number copied off one goes in as it reads.
class SolarPlace {
  const SolarPlace({required this.latitude, required this.longitude});

  /// -90 (the south pole) to 90 (the north).
  final double latitude;

  /// -180 (west) to 180 (east).
  final double longitude;

  bool get isValid =>
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180 &&
      !latitude.isNaN &&
      !longitude.isNaN;

  @override
  bool operator ==(Object other) =>
      other is SolarPlace &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() =>
      'SolarPlace(${latitude.toStringAsFixed(4)}, '
      '${longitude.toStringAsFixed(4)})';
}

/// One day's sun at one place: when it came up, and when it went down.
///
/// Either can be absent, and that is not a failure: above the arctic and
/// below the antarctic circles there are days with no sunrise and days with
/// no sunset, and [daylight] is what says which of the two this is.
class SolarDay {
  const SolarDay({
    required this.sunrise,
    required this.sunset,
    required this.daylight,
  });

  /// The sun's rising and setting, as UTC instants.
  final DateTime? sunrise;
  final DateTime? sunset;

  /// Whether the sun is up for the whole of this day (the midnight sun) or
  /// down for the whole of it (the polar night), where there is no rising
  /// or setting to report.
  final bool daylight;

  bool get isPolar => sunrise == null || sunset == null;
}

/// Sunrise and sunset, worked out rather than looked up.
///
/// The player has no network to ask and no almanac to carry, but the sun's
/// position is a closed-form calculation from a date and a place, so it can
/// simply be computed. This is the standard low-precision solar
/// approximation - good to about a minute, which is far finer than a
/// backlight needs.
abstract final class Solar {
  /// Degrees below the horizon at which the sun counts as risen or set:
  /// the disc's own radius plus the atmosphere's refraction, which is what
  /// makes the published sunrise a little before the geometric one.
  static const _horizon = -0.833;

  /// The earth's axial tilt.
  static const _obliquity = 23.4397;

  /// Julian date of 2000-01-01 12:00 UTC, which every term below counts
  /// from.
  static const _epoch = 2451545.0;

  static const _degrees = math.pi / 180;

  /// The sun's day at [place], for the date [instant] falls on.
  ///
  /// [instant] is read in UTC: the calculation is done in UTC throughout
  /// and the answers come back as UTC instants, so a caller that wants
  /// wall-clock times converts them itself ([DateTime.toLocal]).
  static SolarDay dayAt(SolarPlace place, DateTime instant) {
    final utc = instant.toUtc();
    final julian = _julianDay(utc);
    // The solar day to answer for: the one whose noon is *nearest*
    // [instant], not the next one along. Rounding rather than taking the
    // ceiling is what makes an afternoon belong to its own day - with the
    // ceiling, one o'clock is compared against tomorrow's sunrise and
    // reads as night.
    final n = (julian - _epoch + place.longitude / 360).roundToDouble();
    // Mean solar time at this place, as days since the epoch. East of
    // Greenwich the sun is over the meridian earlier in UTC, which is why
    // the longitude comes off rather than on.
    final mean = n - place.longitude / 360;

    // The sun's mean anomaly: how far round its orbit the earth is.
    final anomaly = (357.5291 + 0.98560028 * mean) % 360;
    final anomalyRad = anomaly * _degrees;

    // The equation of the center, correcting the mean anomaly for the
    // orbit being an ellipse rather than a circle.
    final center =
        1.9148 * math.sin(anomalyRad) +
        0.02 * math.sin(2 * anomalyRad) +
        0.0003 * math.sin(3 * anomalyRad);

    // Where the sun is along the ecliptic. 102.9372 is the argument of
    // perihelion; the 180 turns the earth's position into the sun's.
    final ecliptic = (anomaly + center + 180 + 102.9372) % 360;
    final eclipticRad = ecliptic * _degrees;

    // Solar noon, as a Julian date.
    final transit =
        _epoch +
        mean +
        0.0053 * math.sin(anomalyRad) -
        0.0069 * math.sin(2 * eclipticRad);

    // The sun's declination: how far north or south of the equator it is
    // standing overhead today.
    final declination = math.asin(
      math.sin(eclipticRad) * math.sin(_obliquity * _degrees),
    );

    final latitudeRad = place.latitude * _degrees;
    // The hour angle: how far round from noon the sun crosses the horizon.
    final cosHourAngle =
        (math.sin(_horizon * _degrees) -
            math.sin(latitudeRad) * math.sin(declination)) /
        (math.cos(latitudeRad) * math.cos(declination));

    // Out of range means the sun does not cross the horizon at all today.
    // Above 1 it never climbs to it (the polar night); below -1 it never
    // falls to it (the midnight sun).
    if (cosHourAngle > 1) {
      return const SolarDay(sunrise: null, sunset: null, daylight: false);
    }
    if (cosHourAngle < -1) {
      return const SolarDay(sunrise: null, sunset: null, daylight: true);
    }

    final hourAngle = math.acos(cosHourAngle) / _degrees;
    return SolarDay(
      sunrise: _fromJulian(transit - hourAngle / 360),
      sunset: _fromJulian(transit + hourAngle / 360),
      daylight: true,
    );
  }

  /// Whether the sun is up at [instant], at [place].
  ///
  /// The day is taken from [instant] itself, so an instant in the small
  /// hours is compared against that morning's sunrise: before it, the sun
  /// is still down, which is the answer wanted.
  static bool isDaylight(SolarPlace place, DateTime instant) {
    final day = dayAt(place, instant);
    final sunrise = day.sunrise;
    final sunset = day.sunset;
    if (sunrise == null || sunset == null) return day.daylight;
    final utc = instant.toUtc();
    return !utc.isBefore(sunrise) && utc.isBefore(sunset);
  }

  /// The next time the light changes at [place], after [instant]: the
  /// sunrise or sunset that ends the state [isDaylight] reports now.
  ///
  /// Null where there is neither for as far ahead as it is worth looking -
  /// a polar summer or winter, where the answer is "not for weeks". A
  /// caller wanting to re-check anyway should fall back to its own period.
  static DateTime? nextChange(SolarPlace place, DateTime instant) {
    final utc = instant.toUtc();
    // Today's two, then the next few days': at high latitudes the sun can
    // stay up or down for days at a time before it starts crossing again.
    for (var ahead = 0; ahead <= 4; ahead++) {
      final day = dayAt(place, utc.add(Duration(days: ahead)));
      for (final event in [day.sunrise, day.sunset]) {
        if (event != null && event.isAfter(utc)) return event;
      }
    }
    return null;
  }

  /// The Julian date of a UTC instant.
  static double _julianDay(DateTime utc) =>
      utc.millisecondsSinceEpoch / Duration.millisecondsPerDay + 2440587.5;

  static DateTime _fromJulian(double julian) =>
      DateTime.fromMillisecondsSinceEpoch(
        ((julian - 2440587.5) * Duration.millisecondsPerDay).round(),
        isUtc: true,
      );
}
