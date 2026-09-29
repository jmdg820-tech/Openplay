/// One of the signed-in user's own active registrations, as returned by
/// `get_my_participations()` (migration 028). Only ever the caller's rows --
/// the server derives identity from auth.uid(); no user id is sent or kept.
class MyParticipation {
  final String participantId;
  final String sessionId;
  final String status; // confirmed | waitlisted | pending_confirmation
  final int? secondsUntilExpiry; // only for pending_confirmation
  final int? waitlistPosition; // only for waitlisted
  final String sessionStatus; // active | cancelled
  final DateTime startTime;
  final DateTime endTime;
  final String venueId;

  MyParticipation({
    required this.participantId,
    required this.sessionId,
    required this.status,
    required this.secondsUntilExpiry,
    required this.waitlistPosition,
    required this.sessionStatus,
    required this.startTime,
    required this.endTime,
    required this.venueId,
  });

  /// A waitlist promotion the user still has to confirm (the in-app
  /// delivery of the `waitlist_promoted` event).
  bool get isPendingOffer =>
      status == 'pending_confirmation' && sessionStatus == 'active' && (secondsUntilExpiry ?? 0) > 0;

  /// Plain-language status for lists (My sessions).
  String get statusLabel {
    if (sessionStatus == 'cancelled') return 'Session cancelled';
    switch (status) {
      case 'confirmed':
        return "You're in";
      case 'pending_confirmation':
        return 'Spot offered -- confirm now';
      case 'waitlisted':
        return waitlistPosition == null ? 'On the waitlist' : 'Waitlist #$waitlistPosition';
      default:
        return status;
    }
  }

  factory MyParticipation.fromRow(Map<String, dynamic> row) => MyParticipation(
        participantId: row['participant_id'] as String,
        sessionId: row['session_id'] as String,
        status: row['status'] as String,
        secondsUntilExpiry: row['seconds_until_expiry'] as int?,
        waitlistPosition: row['waitlist_position'] as int?,
        sessionStatus: row['session_status'] as String,
        startTime: DateTime.parse(row['start_time'] as String),
        endTime: DateTime.parse(row['end_time'] as String),
        venueId: row['venue_id'] as String,
      );
}
