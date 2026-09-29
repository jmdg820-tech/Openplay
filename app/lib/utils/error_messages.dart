// `Session` collides with this project's own model, unused here anyway.
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

/// Auth errors (sign up/sign in) -- `AuthException.message` is already a
/// clean, GoTrue-provided human-readable string (e.g. "Invalid login
/// credentials"); the only problem is `Object.toString()` wrapping it as
/// `AuthException(message: ..., statusCode: ..., code: ...)`. This just
/// unwraps it, same "never show raw exception internals" rule as the rest
/// of this file.
String friendlyAuthError(Object error) {
  if (error is AuthException) return error.message;
  return 'Something went wrong. Please try again.';
}

/// Turns a raw report/block RPC failure into a user-facing message.
///
/// Two rules drive this:
///  1. Never surface raw Postgres internals (constraint names, relation
///     names, SQLSTATE codes) to the UI.
///  2. Never let the message distinguish "target is a guest" from any other
///     "can't act on this participant" reason -- report_session_participant()/
///     block_session_participant() already collapse that server-side into
///     one fixed string; this mapping must not re-introduce a side channel
///     by, say, giving the guest case its own friendlier wording while
///     leaving other cases generic (that would itself be distinguishable).
String friendlyReportBlockError(Object error) {
  final raw = error is PostgrestException ? error.message : error.toString();
  final text = raw.toLowerCase();

  if (text.contains('cannot report yourself')) {
    return "You can't report yourself.";
  }
  if (text.contains('blocks_no_self_block')) {
    return "You can't block yourself.";
  }
  if (text.contains('a reason is required')) {
    return 'Please enter a reason.';
  }
  if (text.contains('blocks_unique') || text.contains('duplicate key')) {
    return "You've already blocked this person.";
  }
  if (text.contains('not authorized for this action')) {
    return "This action isn't available right now.";
  }
  if (text.contains('unable to complete this action for the selected participant')) {
    // The guest-target case. It's fine for this to read differently from
    // "not authorized" above -- those really are different scenarios (see
    // the DB migration's own comments and its A7/B7 tests): a caller who
    // is genuinely a member of this session, acting on a real participant_id
    // from THIS session's own roster, can only ever land here for one
    // reason (the target is a guest); they can't reach "not authorized" for
    // a row they're already looking at. What must never happen is this
    // message mentioning "guest" itself, or varying its wording by which
    // underlying condition triggered it -- it's always this one sentence.
    return "This action isn't available for this participant.";
  }

  return 'Something went wrong. Please try again.';
}

/// Same two rules as [friendlyReportBlockError], applied to the other
/// session actions (join/leave/confirm/remove/cancel/edit) that were
/// showing raw `PostgrestException` text directly to users -- e.g.
/// `"Join failed: PostgrestException(message: already joined this
/// session, code: P0001, details: , hint: null)"` (found live during the
/// QA audit). Maps every `raise exception` message actually used by
/// join_session()/leave_session()/confirm_promotion()/remove_participant()/
/// cancel_session() (supabase/migrations 013-015), plus the raw
/// Postgres RLS/CHECK-constraint text that `updateSession()`'s direct
/// table UPDATE can surface, to a plain-language equivalent. Falls back to
/// [friendlyReportBlockError]'s mapping (covers the shared "not authorized"
/// wording) and then to the same generic message if nothing matches --
/// never echoes raw exception internals either.
String friendlyActionError(Object error) {
  final raw = error is PostgrestException ? error.message : error.toString();
  final text = raw.toLowerCase();

  if (text.contains('cannot join as guest while authenticated')) {
    return "You're signed in -- join as yourself instead of as a guest.";
  }
  if (text.contains('guest name and a contact method')) {
    return 'Enter your name and a phone number or email to join as a guest.';
  }
  if (text.contains('a guest with this contact info has already joined')) {
    return "A guest with that contact info has already joined this session.";
  }
  if (text.contains('already joined this session')) {
    return "You've already joined this session.";
  }
  if (text.contains('session not found') || text.contains('participant not found')) {
    return "That couldn't be found -- it may have been removed.";
  }
  if (text.contains('session is already cancelled')) {
    return 'This session is already cancelled.';
  }
  if (text.contains('session is not active')) {
    return 'This session is no longer active.';
  }
  if (text.contains('this participation is not active')) {
    return 'This registration is no longer active.';
  }
  if (text.contains('this offer has expired')) {
    return 'Your spot offer has expired.';
  }
  if (text.contains('a cancellation reason is required')) {
    return 'Please enter a reason for cancelling.';
  }
  if (text.contains('session has already ended')) {
    return 'This session has already ended.';
  }
  // Guest limits (migration 029).
  if (text.contains('guest spots for this session are full')) {
    return 'Guest spots for this session are full -- sign in to join as yourself.';
  }
  if (text.contains('too many guest sign-ups')) {
    return 'Too many guest sign-ups for this session right now. Please try again in a few minutes.';
  }
  if (text.contains('guest name must be between')) {
    return 'Enter a name of up to 80 characters.';
  }
  if (text.contains('guest contact must be at most')) {
    return 'That contact is too long.';
  }
  // Capacity reconciliation (migration 030).
  if (text.contains('capacity cannot be lower than the number of players holding a spot')) {
    final count = RegExp(r'\((\d+)\)').firstMatch(raw)?.group(1);
    return count == null
        ? "Capacity can't be lower than the number of players already holding a spot."
        : "Capacity can't be lower than the $count players already holding a spot. Remove players first.";
  }
  if (text.contains('authentication required')) {
    return 'Please sign in first.';
  }
  if (text.contains('row-level security') || text.contains('violates row-level security policy')) {
    return "You're not able to edit this session.";
  }
  if (text.contains('sessions_capacity_check')) {
    return 'Capacity is too low for this session type.';
  }
  if (text.contains('sessions_time_check')) {
    return 'The end time must be after the start time.';
  }

  return friendlyReportBlockError(error);
}
