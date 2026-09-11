import 'package:flutter_test/flutter_test.dart';
import 'package:openplay_app/utils/error_messages.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

PostgrestException _pg(String message) => PostgrestException(message: message);

void main() {
  group('friendlyReportBlockError', () {
    test('maps self-report', () {
      expect(friendlyReportBlockError(_pg('cannot report yourself')), contains('report yourself'));
    });

    test('maps self-block constraint violation without leaking the constraint name', () {
      final msg = friendlyReportBlockError(
        _pg('new row for relation "blocks" violates check constraint "blocks_no_self_block"'),
      );
      expect(msg, contains('block yourself'));
      expect(msg, isNot(contains('constraint')));
      expect(msg, isNot(contains('relation')));
    });

    test('maps missing reason', () {
      expect(friendlyReportBlockError(_pg('a reason is required')), contains('reason'));
    });

    test('maps duplicate block without leaking the constraint/index name', () {
      final msg = friendlyReportBlockError(
        _pg('duplicate key value violates unique constraint "blocks_unique"'),
      );
      expect(msg.toLowerCase(), contains('already blocked'));
      expect(msg, isNot(contains('blocks_unique')));
    });

    test('maps not-authorized (unknown/cross-session/non-member target)', () {
      final msg = friendlyReportBlockError(_pg('not authorized for this action'));
      expect(msg, isNotEmpty);
      expect(msg.toLowerCase(), isNot(contains('guest')));
    });

    test('maps guest-target rejection WITHOUT ever mentioning "guest"', () {
      final msg = friendlyReportBlockError(
        _pg('unable to complete this action for the selected participant'),
      );
      expect(msg, isNotEmpty);
      expect(msg.toLowerCase(), isNot(contains('guest')));
    });

    test('the guest-target and not-authorized messages read differently from each other '
        '(expected -- see the migration/UI comments on why that split is not a side channel), '
        'but NEITHER ever contains the word guest', () {
      final notAuthorized = friendlyReportBlockError(_pg('not authorized for this action'));
      final guestTarget = friendlyReportBlockError(
        _pg('unable to complete this action for the selected participant'),
      );
      expect(notAuthorized.toLowerCase(), isNot(contains('guest')));
      expect(guestTarget.toLowerCase(), isNot(contains('guest')));
    });

    test('falls back to a generic message for anything unrecognized, never echoing raw internals', () {
      final msg = friendlyReportBlockError(
        _pg('relation "session_participants" permission denied for role anon at character 15'),
      );
      expect(msg, 'Something went wrong. Please try again.');
    });

    test('handles a plain non-Postgrest error object too (e.g. a network failure)', () {
      final msg = friendlyReportBlockError(Exception('SocketException: Connection refused'));
      expect(msg, 'Something went wrong. Please try again.');
    });
  });
}
