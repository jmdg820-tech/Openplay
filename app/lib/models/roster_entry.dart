/// Mirrors the exact, and ONLY, columns `get_session_roster()` returns.
/// There is deliberately no `userId`, `guestName`, `guestContact`,
/// `managementToken`, `waitlistOrderAt`, `promotedAt`, `promotionExpiresAt`,
/// `joinedAt`, or `createdAt`/`updatedAt` field here — the RPC never sends
/// them, so this model has nowhere to put them even by mistake.
class RosterEntry {
  final String participantId;
  final String sessionId;
  final String displayName;
  final String status; // confirmed | waitlisted | pending_confirmation | left | removed
  final String? skillLevel; // null unless the viewer is entitled to see it
  final int? secondsUntilExpiry; // only meaningful for pending_confirmation

  /// NULL for anonymous/non-member/plain-participant viewers by server
  /// design (only organizer/staff are told who's a guest) -- kept nullable
  /// here rather than defaulted to `false` so the UI can honestly render
  /// "unknown" instead of implying "definitely registered".
  final bool? isGuest;

  RosterEntry({
    required this.participantId,
    required this.sessionId,
    required this.displayName,
    required this.status,
    required this.skillLevel,
    required this.secondsUntilExpiry,
    required this.isGuest,
  });

  factory RosterEntry.fromRow(Map<String, dynamic> row) => RosterEntry(
        participantId: row['participant_id'] as String,
        sessionId: row['session_id'] as String,
        displayName: row['display_name'] as String? ?? '(unknown)',
        status: row['status'] as String,
        skillLevel: row['skill_level'] as String?,
        secondsUntilExpiry: row['seconds_until_expiry'] as int?,
        isGuest: row['is_guest'] as bool?,
      );
}
