import 'package:flutter_test/flutter_test.dart';
import 'package:openplay_app/utils/geo.dart';

void main() {
  group('tryParseLocation', () {
    test('parses a GeoJSON Point map (the PostGIS/PostgREST common case)', () {
      final p = tryParseLocation({
        'type': 'Point',
        'coordinates': [121.05, 14.55], // [lng, lat]
      });
      expect(p, isNotNull);
      expect(p!.lat, 14.55);
      expect(p.lng, 121.05);
    });

    test('parses a GeoJSON Point encoded as a JSON string', () {
      final p = tryParseLocation('{"type":"Point","coordinates":[-122.4,37.8]}');
      expect(p, isNotNull);
      expect(p!.lat, 37.8);
      expect(p.lng, -122.4);
    });

    test('parses WKT POINT(lng lat) text', () {
      final p = tryParseLocation('POINT(121.05 14.55)');
      expect(p, isNotNull);
      expect(p!.lat, 14.55);
      expect(p.lng, 121.05);
    });

    test('parses WKT case-insensitively', () {
      final p = tryParseLocation('point(-122.4 37.8)');
      expect(p, isNotNull);
      expect(p!.lat, 37.8);
    });

    test('parses the EXACT live EWKB hex returned by the real Supabase project', () {
      // Captured directly from a real REST call against the live OpenPlay
      // project for a venue stored as POINT(121.05 14.55) -- see the live
      // verification report. This is the actual wire format PostgREST
      // sends for a `geography(Point,4326)` column, not a hypothetical.
      const liveHex = '0101000020E61000003333333333435E409A99999999192D40';
      final p = tryParseLocation(liveHex);
      expect(p, isNotNull, reason: 'must decode the real live wire format, not just WKT/GeoJSON');
      expect(p!.lng, closeTo(121.05, 1e-9));
      expect(p.lat, closeTo(14.55, 1e-9));
    });

    test('parses EWKB hex lowercase too (hex is case-insensitive)', () {
      const liveHex = '0101000020E61000003333333333435E409A99999999192D40';
      final p = tryParseLocation(liveHex.toLowerCase());
      expect(p, isNotNull);
      expect(p!.lng, closeTo(121.05, 1e-9));
      expect(p.lat, closeTo(14.55, 1e-9));
    });

    test('parses a plain WKB point with no SRID flag (0101000000...)', () {
      // Same X/Y, but type word 00000001 (no 0x20000000 SRID bit) and no
      // SRID field -- X/Y bytes follow immediately after the type word.
      const noSridHex = '01010000003333333333435E409A99999999192D40';
      final p = tryParseLocation(noSridHex);
      expect(p, isNotNull);
      expect(p!.lng, closeTo(121.05, 1e-9));
      expect(p.lat, closeTo(14.55, 1e-9));
    });

    test('parses negative coordinates via EWKB correctly', () {
      // POINT(-122.4 37.8) with SRID 4326, little-endian.
      const hex = '0101000020E61000009A99999999995EC06666666666E64240';
      final p = tryParseLocation(hex);
      expect(p, isNotNull);
      expect(p!.lng, closeTo(-122.4, 1e-9));
      expect(p.lat, closeTo(37.8, 1e-9));
    });

    test('returns null (never throws) for truncated/malformed EWKB hex', () {
      const truncated = '0101000020E6100000333333333343';
      expect(() => tryParseLocation(truncated), returnsNormally);
      expect(tryParseLocation(truncated), isNull);
    });

    test('returns null (never throws) for an unsupported EWKB geometry type (LineString)', () {
      // Type word 00000002 = LineString, not Point -- must be rejected,
      // not misread as a point.
      const lineStringHex = '0102000000020000000000000000000000000000000000000000000000000000F03F000000000000F03F';
      expect(() => tryParseLocation(lineStringHex), returnsNormally);
      expect(tryParseLocation(lineStringHex), isNull);
    });

    test('returns null for a placeholder ellipsis string (not real hex)', () {
      expect(
        () => tryParseLocation('0101000020E6100000...'),
        returnsNormally,
      );
      expect(tryParseLocation('0101000020E6100000...'), isNull);
    });

    test('returns null for out-of-range decoded coordinates rather than trusting garbage bytes', () {
      // Well-formed-looking EWKB header but X/Y bytes decode to something
      // outside valid lat/lng range -- must not be surfaced as a location.
      const outOfRangeHex = '0101000020E6100000000000000000F07F000000000000F07F';
      expect(tryParseLocation(outOfRangeHex), isNull);
    });

    test('returns null for null input', () {
      expect(tryParseLocation(null), isNull);
    });

    test('returns null for empty string input', () {
      expect(tryParseLocation(''), isNull);
      expect(tryParseLocation('   '), isNull);
    });

    test('returns null for garbage input, never throws', () {
      expect(() => tryParseLocation('not a location'), returnsNormally);
      expect(tryParseLocation('not a location'), isNull);
      expect(() => tryParseLocation(12345), returnsNormally);
      expect(tryParseLocation(12345), isNull);
      expect(() => tryParseLocation(true), returnsNormally);
      expect(tryParseLocation(true), isNull);
      expect(() => tryParseLocation([1, 2, 3]), returnsNormally);
      expect(tryParseLocation([1, 2, 3]), isNull);
    });

    test('returns null for odd-length hex-looking strings (cannot be valid bytes)', () {
      expect(tryParseLocation('0101000020E610000'), isNull);
    });
  });

  group('haversineKm', () {
    test('distance between a point and itself is zero', () {
      const p = GeoPoint(14.55, 121.05);
      expect(haversineKm(p, p), closeTo(0, 1e-9));
    });

    test('Manila to Cebu is roughly 570km (known real-world distance)', () {
      const manila = GeoPoint(14.5995, 120.9842);
      const cebu = GeoPoint(10.3157, 123.8854);
      final km = haversineKm(manila, cebu);
      expect(km, greaterThan(550));
      expect(km, lessThan(600));
    });

    test('is symmetric', () {
      const a = GeoPoint(1.0, 2.0);
      const b = GeoPoint(3.0, 4.0);
      expect(haversineKm(a, b), closeTo(haversineKm(b, a), 1e-9));
    });
  });
}
