// `Session` collides with this project's own model, unused here anyway.
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

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
