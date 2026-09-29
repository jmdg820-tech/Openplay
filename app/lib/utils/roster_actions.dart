import '../models/roster_entry.dart';

const _activeStatuses = {'confirmed', 'waitlisted', 'pending_confirmation'};

/// Whether [entry] belongs to the current viewer.
///
/// Registered users: decided by the SERVER (`is_self`, derived from
/// auth.uid() in get_session_roster()), so it survives navigating away,
/// reopening the session, and app restarts -- no client memory involved.
/// Guests: they have no auth identity, so ownership is proven only by
/// holding that row's management token (captured at join time or re-entered
/// via their saved guest code) -- [guestTokens] maps participantId -> token.
bool isMyEntry(RosterEntry entry, Map<String, String?> guestTokens) =>
    entry.isSelf || guestTokens.containsKey(entry.participantId);

/// Leave is offered only on the viewer's own, still-active row.
bool canLeave(RosterEntry entry, Map<String, String?> guestTokens) =>
    isMyEntry(entry, guestTokens) && _activeStatuses.contains(entry.status);

/// Confirm is offered only on the viewer's own row while a promotion offer
/// is pending. The server is still the authority (it rejects an expired or
/// already-confirmed offer); this only decides whether to show the button.
bool canConfirm(RosterEntry entry, Map<String, String?> guestTokens) =>
    isMyEntry(entry, guestTokens) && entry.status == 'pending_confirmation';

/// True when the signed-in viewer already holds an active registration in
/// this roster -- used to stop offering "Join" again (the server would just
/// reject it with "already joined").
bool hasActiveSelfEntry(Iterable<RosterEntry> roster) =>
    roster.any((e) => e.isSelf && _activeStatuses.contains(e.status));

/// Spots counted against capacity -- confirmed AND pending offers, exactly
/// the rule join_session()/promote_next_waitlisted() use server-side.
int occupiedSpots(Iterable<RosterEntry> roster) =>
    roster.where((e) => e.status == 'confirmed' || e.status == 'pending_confirmation').length;

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
