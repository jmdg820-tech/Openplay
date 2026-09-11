class Session {
  final String id;
  final String venueId;
  final String createdBy;
  final String sessionType; // singles | doubles
  final DateTime startTime;
  final DateTime endTime;
  final int capacity;
  final String status; // active | cancelled
  final String? cancellationReason;
  final String? skillLevelInfo;

  Session({
    required this.id,
    required this.venueId,
    required this.createdBy,
    required this.sessionType,
    required this.startTime,
    required this.endTime,
    required this.capacity,
    required this.status,
    required this.cancellationReason,
    required this.skillLevelInfo,
  });

  bool get isCancelled => status == 'cancelled';

  factory Session.fromRow(Map<String, dynamic> row) => Session(
        id: row['id'] as String,
        venueId: row['venue_id'] as String,
        createdBy: row['created_by'] as String,
        sessionType: row['session_type'] as String,
        startTime: DateTime.parse(row['start_time'] as String),
        endTime: DateTime.parse(row['end_time'] as String),
        capacity: row['capacity'] as int,
        status: row['status'] as String,
        cancellationReason: row['cancellation_reason'] as String?,
        skillLevelInfo: row['skill_level_info'] as String?,
      );
}
