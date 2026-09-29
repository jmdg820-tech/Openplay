import 'package:flutter_test/flutter_test.dart';
import 'package:openplay_app/utils/error_messages.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

PostgrestException _pg(String message) => PostgrestException(message: message);

void main() {
  group('friendlyAuthError', () {
    test('unwraps AuthException.message instead of showing the wrapper', () {
      final msg = friendlyAuthError(const AuthException('Invalid login credentials'));
      expect(msg, 'Invalid login credentials');
      expect(msg, isNot(contains('AuthException')));
      expect(msg, isNot(contains('statusCode')));
    });

    test('falls back to a generic message for a non-auth error', () {
      expect(friendlyAuthError(Exception('boom')), 'Something went wrong. Please try again.');
    });
  });


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

  group('friendlyActionError', () {
    test('maps duplicate join', () {
      final msg = friendlyActionError(_pg('already joined this session'));
      expect(msg.toLowerCase(), contains('already joined'));
      expect(msg, isNot(contains('PostgrestException')));
      expect(msg, isNot(contains('P0001')));
    });

    test('maps guest join while authenticated', () {
      final msg = friendlyActionError(_pg('cannot join as guest while authenticated'));
      expect(msg, isNotEmpty);
      expect(msg, isNot(contains('PostgrestException')));
    });

    test('maps missing guest fields', () {
      final msg = friendlyActionError(
        _pg('guest name and a contact method (phone or email) are required'),
      );
      expect(msg.toLowerCase(), contains('name'));
    });

    test('maps duplicate guest contact', () {
      final msg = friendlyActionError(
        _pg('a guest with this contact info has already joined this session'),
      );
      expect(msg.toLowerCase(), contains('already joined'));
    });

    test('maps session/participant not found', () {
      expect(friendlyActionError(_pg('session not found')), isNot(contains('PostgrestException')));
      expect(friendlyActionError(_pg('participant not found')), isNot(contains('PostgrestException')));
    });

    test('maps session already cancelled', () {
      expect(friendlyActionError(_pg('session is already cancelled')).toLowerCase(), contains('cancelled'));
    });

    test('maps session no longer active', () {
      expect(friendlyActionError(_pg('session is not active')).toLowerCase(), contains('active'));
    });

    test('maps inactive participation (already left/removed)', () {
      expect(
        friendlyActionError(_pg('this participation is not active')).toLowerCase(),
        contains('registration'),
      );
    });

    test('maps expired promotion offer', () {
      expect(
        friendlyActionError(_pg('this offer has expired or is no longer available')).toLowerCase(),
        contains('expired'),
      );
    });

    test('maps missing cancellation reason', () {
      expect(
        friendlyActionError(_pg('a cancellation reason is required')).toLowerCase(),
        contains('reason'),
      );
    });

    test('maps organizer/staff-only rejection (shared with report/block wording)', () {
      final msg = friendlyActionError(_pg('not authorized for this action'));
      expect(msg, isNotEmpty);
      expect(msg, isNot(contains('PostgrestException')));
    });

    test('maps a raw RLS violation from the direct-table session edit path, without leaking policy internals', () {
      final msg = friendlyActionError(
        _pg('new row violates row-level security policy for table "sessions"'),
      );
      expect(msg.toLowerCase(), contains('edit'));
      expect(msg, isNot(contains('policy')));
      expect(msg, isNot(contains('"sessions"')));
    });

    test('maps the capacity CHECK constraint without leaking the constraint name', () {
      final msg = friendlyActionError(
        _pg('new row for relation "sessions" violates check constraint "sessions_capacity_check"'),
      );
      expect(msg.toLowerCase(), contains('capacity'));
      expect(msg, isNot(contains('sessions_capacity_check')));
    });

    test('maps the time-ordering CHECK constraint without leaking the constraint name', () {
      final msg = friendlyActionError(
        _pg('new row for relation "sessions" violates check constraint "sessions_time_check"'),
      );
      expect(msg.toLowerCase(), contains('end time'));
      expect(msg, isNot(contains('sessions_time_check')));
    });

    test('falls back through friendlyReportBlockError for anything else, never echoing raw internals', () {
      final msg = friendlyActionError(
        _pg('relation "session_participants" permission denied for role anon at character 15'),
      );
      expect(msg, 'Something went wrong. Please try again.');
    });

    test('maps an ended session (migration 026)', () {
      expect(friendlyActionError(_pg('session has already ended')), 'This session has already ended.');
    });

    test('maps the guest cap, guest rate limit, and guest input bounds (migration 029)', () {
      expect(friendlyActionError(_pg('guest spots for this session are full')).toLowerCase(),
          contains('guest spots'));
      expect(friendlyActionError(_pg('too many guest sign-ups for this session right now')).toLowerCase(),
          contains('try again'));
      expect(friendlyActionError(_pg('guest name must be between 1 and 80 characters')), contains('80'));
      expect(friendlyActionError(_pg('guest contact must be at most 254 characters')).toLowerCase(),
          contains('too long'));
    });

    test('maps capacity-below-occupied (migration 030) with the player count, no raw internals', () {
      final msg = friendlyActionError(
        _pg('capacity cannot be lower than the number of players holding a spot (5)'),
      );
      expect(msg, contains('5 players'));
      expect(msg, isNot(contains('PostgrestException')));
    });
  });
}
