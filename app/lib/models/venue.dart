import '../utils/geo.dart';

class Venue {
  final String id;
  final String name;
  final String? addressText;
  final int? numberOfCourts;
  final String? hoursInfo;
  final String createdBy;

  /// Best-effort parsed coordinates from the `location` column -- see
  /// utils/geo.dart for exactly which formats this can and can't read.
  /// Null means "unknown to this client", not "venue has no location".
  final GeoPoint? coordinates;

  Venue({
    required this.id,
    required this.name,
    required this.addressText,
    required this.numberOfCourts,
    required this.hoursInfo,
    required this.createdBy,
    required this.coordinates,
  });

  factory Venue.fromRow(Map<String, dynamic> row) => Venue(
        id: row['id'] as String,
        name: row['name'] as String,
        addressText: row['address_text'] as String?,
        numberOfCourts: row['number_of_courts'] as int?,
        hoursInfo: row['hours_info'] as String?,
        createdBy: row['created_by'] as String,
        coordinates: tryParseLocation(row['location']),
      );
}
