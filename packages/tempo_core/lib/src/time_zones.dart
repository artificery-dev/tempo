import 'dart:io';

import 'solar.dart';

/// One row of the system's zone table: a zone, and where on the earth it
/// stands for.
class TimeZone implements Comparable<TimeZone> {
  const TimeZone({required this.id, required this.place, this.comment});

  /// The IANA name, as `/etc/localtime` would be pointed at:
  /// `Europe/Andorra`, `America/New_York`.
  final String id;

  /// The zone's representative place - a principal city, near enough.
  final SolarPlace place;

  /// What the table says to tell one zone from another where a country has
  /// several: 'Casey', 'most of Chile'. Null for most rows.
  final String? comment;

  /// The part before the first slash: `Europe`, `America`, `Pacific`. The
  /// zones are walked by area, because three hundred rows in one list is
  /// not a list anybody walks with a wheel.
  String get area {
    final slash = id.indexOf('/');
    return slash < 0 ? id : id.substring(0, slash);
  }

  /// The rest of it, read as words: `New_York` is a filename, and `New
  /// York` is what a person is looking for. Deeper names keep their later
  /// slashes as commas - `America/Indiana/Knox` reads `Indiana, Knox`.
  String get location {
    final slash = id.indexOf('/');
    if (slash < 0) return id;
    return id.substring(slash + 1).replaceAll('_', ' ').replaceAll('/', ', ');
  }

  /// The line the picker shows: the place, and the table's note where it
  /// has one to tell two rows apart.
  String get label => comment == null ? location : '$location - $comment';

  /// By area first and then by place, which is the order they are shown
  /// in.
  @override
  int compareTo(TimeZone other) {
    final byArea = area.compareTo(other.area);
    return byArea != 0 ? byArea : location.compareTo(other.location);
  }

  @override
  String toString() => 'TimeZone($id)';
}

/// The zones this machine knows about, and where they are.
///
/// Read from tzdb's own table rather than carried as a list of our own:
/// the zones a player can be set to should be the zones its `/usr/share/
/// zoneinfo` actually has, and the table beside them is already a map from
/// each one to a place - which is the whole of what [AppearanceMode.auto]
/// needs to know where the sun is.
///
/// Read once, on the first ask. A machine with no table at all - a rootfs
/// built without tzdata - gets an empty list, and everything downstream is
/// written to mean "no place, then", not to fail.
abstract final class TimeZones {
  /// Where the table lives. `zone1970.tab` is the modern one; `zone.tab`
  /// is the same shape and is what an older or trimmed tzdata leaves.
  static const tables = [
    '/usr/share/zoneinfo/zone1970.tab',
    '/usr/share/zoneinfo/zone.tab',
  ];

  /// The zone that means "no place": the clock without a country. It is
  /// not in the table - the table is a list of inhabited places - so it is
  /// named here, and [placeOf] answers null for it.
  static const utc = 'UTC';

  static List<TimeZone>? _all;

  /// Every zone the table offered, in the order the picker shows them.
  static List<TimeZone> get all => _all ??= _read();

  /// Forget what was read, so the next ask reads again. For tests, and for
  /// a machine whose zoneinfo has just been installed under it.
  static void reload() => _all = null;

  /// The areas, in order: `Africa`, `America`, ... The first page of the
  /// picker.
  static List<String> get areas {
    final seen = <String>{for (final zone in all) zone.area};
    return seen.toList()..sort();
  }

  static List<TimeZone> inArea(String area) => [
    for (final zone in all)
      if (zone.area == area) zone,
  ];

  static TimeZone? at(String id) {
    for (final zone in all) {
      if (zone.id == id) return zone;
    }
    return null;
  }

  /// Where a zone stands, for the sun's sake. Null for a zone this machine
  /// does not have, and for [utc], which is a clock rather than a place.
  static SolarPlace? placeOf(String? id) =>
      id == null || id == utc ? null : at(id)?.place;

  static List<TimeZone> _read() {
    for (final path in tables) {
      try {
        final file = File(path);
        if (!file.existsSync()) continue;
        final zones = parse(file.readAsStringSync());
        if (zones.isNotEmpty) return zones;
      } on FileSystemException {
        // The next candidate, or none.
      }
    }
    return const [];
  }

  /// Parse a zone table: tab-separated, `#` comments, one zone a line.
  ///
  /// ```
  /// AD          +4230+00131      Europe/Andorra
  /// AQ          -6617+11031      Antarctica/Casey    Casey
  /// ```
  ///
  /// Columns after the third are the note. A row whose coordinates will
  /// not parse is dropped rather than guessed at.
  static List<TimeZone> parse(String text) {
    final zones = <TimeZone>[];
    for (final line in text.split('\n')) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final fields = line.split('\t');
      if (fields.length < 3) continue;
      final place = parseCoordinates(fields[1]);
      if (place == null) continue;
      final comment = fields.length > 3 && fields[3].trim().isNotEmpty
          ? fields[3].trim()
          : null;
      zones.add(TimeZone(id: fields[2].trim(), place: place, comment: comment));
    }
    return zones..sort();
  }

  /// ISO 6709 as the table writes it: `+4230+00131` (degrees and minutes)
  /// or `+491900-0771500` (with seconds). Latitude first, two digits of
  /// degrees; longitude second, three.
  static SolarPlace? parseCoordinates(String field) {
    final text = field.trim();
    // The two widths the table uses: sign + DDMM + sign + DDDMM, and the
    // same with seconds on both.
    final (latitudeWidth, seconds) = switch (text.length) {
      11 => (5, false),
      15 => (7, true),
      _ => (0, false),
    };
    if (latitudeWidth == 0) return null;

    final latitude = _degrees(
      text.substring(0, latitudeWidth),
      degreeDigits: 2,
      seconds: seconds,
    );
    final longitude = _degrees(
      text.substring(latitudeWidth),
      degreeDigits: 3,
      seconds: seconds,
    );
    if (latitude == null || longitude == null) return null;
    final place = SolarPlace(latitude: latitude, longitude: longitude);
    return place.isValid ? place : null;
  }

  /// One signed `±DD[D]MM[SS]` field as a decimal degree.
  static double? _degrees(
    String text, {
    required int degreeDigits,
    required bool seconds,
  }) {
    if (text.length < 1 + degreeDigits + 2) return null;
    final sign = switch (text[0]) {
      '+' => 1.0,
      '-' => -1.0,
      _ => null,
    };
    if (sign == null) return null;

    final digits = text.substring(1);
    final degrees = int.tryParse(digits.substring(0, degreeDigits));
    final minutes = int.tryParse(
      digits.substring(degreeDigits, degreeDigits + 2),
    );
    final rest = seconds ? int.tryParse(digits.substring(degreeDigits + 2)) : 0;
    if (degrees == null || minutes == null || rest == null) return null;

    return sign * (degrees + minutes / 60 + rest / 3600);
  }
}
