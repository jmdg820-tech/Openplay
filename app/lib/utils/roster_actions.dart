import '../models/roster_entry.dart';

/// Whether the report/block actions should be offered for this roster row.
///
/// `get_session_roster()` only tells a viewer `is_guest` when they're the
/// session's organizer or venue staff -- an ordinary joined participant
/// always sees `null` for every row, including real guest rows (this is a
/// deliberate privacy choice on the server, not a bug). So this can only
/// ever be a DENY-list: hide the action when the server has told THIS
/// viewer, for certain, that the row is a guest (`isGuest == true`); show
/// it otherwise (`false` or unknown/`null`). An unauthorized or
/// guest-targeted attempt still fails safely server-side (see
/// error_messages.dart) -- this predicate is a UX nicety, not the
/// authorization boundary.
bool canReportOrBlock(
  RosterEntry entry, {
  required bool isMine,
  required bool isSignedIn,
}) {
  if (!isSignedIn) return false;
  if (isMine) return false;
  if (entry.isGuest == true) return false;
  return true;
}
