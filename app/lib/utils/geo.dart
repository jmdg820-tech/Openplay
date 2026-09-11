import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// A plain lat/lng pair. Not named `LatLng` to avoid colliding with any
/// mapping package the app might add later.
class GeoPoint {
  final double lat;
  final double lng;
  const GeoPoint(this.lat, this.lng);
}

/// Great-circle distance between two points, in kilometers.
double haversineKm(GeoPoint a, GeoPoint b) {
  const earthRadiusKm = 6371.0;
  final dLat = _deg2rad(b.lat - a.lat);
  final dLng = _deg2rad(b.lng - a.lng);
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_deg2rad(a.lat)) *
          math.cos(_deg2rad(b.lat)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  final c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  return earthRadiusKm * c;
}

double _deg2rad(double deg) => deg * (math.pi / 180.0);

/// Best-effort parse of whatever PostgREST hands back for a PostGIS
/// `geography(Point,4326)` column selected as a plain column value.
///
/// Confirmed live against the real OpenPlay Supabase project (see the live
/// verification report): PostgREST returns this column as raw EWKB hex,
/// e.g. `"0101000020E61000003333333333435E409A99999999192D40"` -- NOT
/// GeoJSON or WKT. GeoJSON/WKT support is kept for robustness (a future
/// client-side cast to text/GeoJSON, or a differently-configured query,
/// could produce either), but EWKB is the format that actually arrives
/// today and is decoded directly, not delegated to a database-side helper.
///
/// Only a plain 2D Point is understood (with or without the EWKB SRID
/// flag/Z/M dimensions present in the header -- Z/M values themselves, if
/// present, are read past and ignored since this app only ever stores 2D
/// points). Anything else -- wrong geometry type, truncated bytes, garbage
/// hex, out-of-range coordinates -- returns null rather than guessing. A
/// venue whose location can't be parsed simply doesn't participate in
/// "nearby" sorting/filtering; it still shows up in the unsorted list.
/// Never throws, never fabricates a location.
GeoPoint? tryParseLocation(dynamic raw) {
  if (raw == null) return null;

  // GeoJSON object: {"type":"Point","coordinates":[lng,lat]}
  if (raw is Map) {
    final coords = raw['coordinates'];
    if (coords is List && coords.length >= 2) {
      final lng = _asDouble(coords[0]);
      final lat = _asDouble(coords[1]);
      if (_isValidLatLng(lat, lng)) return GeoPoint(lat!, lng!);
    }
    return null;
  }

  if (raw is String) {
    final s = raw.trim();
    if (s.isEmpty) return null;

    // GeoJSON encoded as a JSON string.
    if (s.startsWith('{')) {
      try {
        final decoded = jsonDecode(s);
        if (decoded is Map) return tryParseLocation(decoded);
      } catch (_) {
        // fall through
      }
      return null;
    }

    // WKT: "POINT(lng lat)" (case-insensitive, optional SRID prefix).
    final wkt = RegExp(r'POINT\s*\(\s*([-\d.]+)\s+([-\d.]+)\s*\)', caseSensitive: false);
    final match = wkt.firstMatch(s);
    if (match != null) {
      final lng = double.tryParse(match.group(1)!);
      final lat = double.tryParse(match.group(2)!);
      if (_isValidLatLng(lat, lng)) return GeoPoint(lat!, lng!);
      return null;
    }

    // EWKB hex -- the actual live PostgREST representation for this column.
    if (_looksLikeHex(s)) return _tryParseEwkbPoint(s);

    return null;
  }

  return null;
}

bool _isValidLatLng(double? lat, double? lng) {
  if (lat == null || lng == null) return false;
  if (lat.isNaN || lng.isNaN || lat.isInfinite || lng.isInfinite) return false;
  return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
}

bool _looksLikeHex(String s) {
  if (s.length < 18 || s.length.isOdd) return false;
  return RegExp(r'^[0-9a-fA-F]+$').hasMatch(s);
}

/// Decodes a WKB/EWKB-encoded 2D Point from its hex representation.
/// Layout: 1 byte byte-order, 4 bytes type (with optional Z/M/SRID flags in
/// the high byte), optional 4-byte SRID, then X (lng) and Y (lat) as two
/// 8-byte floats in the declared byte order. Any trailing Z/M bytes are
/// ignored. Returns null (never throws) for anything that isn't a
/// well-formed, in-range 2D/Z/M point.
GeoPoint? _tryParseEwkbPoint(String hex) {
  try {
    final byteCount = hex.length ~/ 2;
    final bytes = Uint8List(byteCount);
    for (var i = 0; i < byteCount; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    final data = ByteData.sublistView(bytes);

    var offset = 0;
    final byteOrderByte = data.getUint8(offset);
    offset += 1;
    final endian = byteOrderByte == 0 ? Endian.big : Endian.little;

    if (data.lengthInBytes < offset + 4) return null;
    final typeAndFlags = data.getUint32(offset, endian);
    offset += 4;

    const wkbZFlag = 0x80000000;
    const wkbMFlag = 0x40000000;
    const wkbSridFlag = 0x20000000;
    final hasSrid = (typeAndFlags & wkbSridFlag) != 0;
    final hasZ = (typeAndFlags & wkbZFlag) != 0;
    final hasM = (typeAndFlags & wkbMFlag) != 0;
    final baseType = typeAndFlags & 0xff;
    if (baseType != 1) return null; // only Point is supported

    if (hasSrid) {
      if (data.lengthInBytes < offset + 4) return null;
      offset += 4; // SRID value itself is not needed by this app
    }

    if (data.lengthInBytes < offset + 16) return null;
    final lng = data.getFloat64(offset, endian);
    offset += 8;
    final lat = data.getFloat64(offset, endian);
    offset += 8;
    // Z and/or M values, if present, are intentionally skipped/unused.
    if (hasZ) offset += 8;
    if (hasM) offset += 8;

    if (!_isValidLatLng(lat, lng)) return null;
    return GeoPoint(lat, lng);
  } catch (_) {
    return null;
  }
}

double? _asDouble(dynamic v) {
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}
