import 'package:flutter_test/flutter_test.dart';
import 'package:openplay_app/models/roster_entry.dart';
import 'package:openplay_app/utils/roster_actions.dart';

RosterEntry _entry({
  String id = 'p1',
  String status = 'confirmed',
  bool? isGuest,
  bool isSelf = false,
}) =>
    RosterEntry(
      participantId: id,
      sessionId: 's1',
      displayName: 'Someone',
      status: status,
      skillLevel: null,
      secondsUntilExpiry: null,
      isGuest: isGuest,
      isSelf: isSelf,
    );

void main() {
  // Each "fresh screen" case below uses an EMPTY guest-token map: that is
  // exactly the state after navigating away and back, or restarting the
  // app. Ownership must then come from the server's is_self alone.
  const noMemory = <String, String?>{};

  group('isMyEntry / canLeave / canConfirm', () {
    test('confirmed participant returning to the screen still gets Leave (server is_self)', () {
      final mine = _entry(isSelf: true);
      expect(isMyEntry(mine, noMemory), isTrue);
      expect(canLeave(mine, noMemory), isTrue);
      expect(canConfirm(mine, noMemory), isFalse);
    });

    test('waitlisted participant returning to the screen still gets Leave', () {
      final mine = _entry(status: 'waitlisted', isSelf: true);
      expect(canLeave(mine, noMemory), isTrue);
      expect(canConfirm(mine, noMemory), isFalse);
    });

    test('promoted participant returning after a restart gets Confirm (and Leave)', () {
      final mine = _entry(status: 'pending_confirmation', isSelf: true);
      expect(canConfirm(mine, noMemory), isTrue);
      expect(canLeave(mine, noMemory), isTrue);
    });

    test("a different user's rows never get Leave/Confirm", () {
      for (final status in ['confirmed', 'waitlisted', 'pending_confirmation']) {
        final theirs = _entry(status: status, isSelf: false);
        expect(isMyEntry(theirs, noMemory), isFalse);
        expect(canLeave(theirs, noMemory), isFalse, reason: status);
        expect(canConfirm(theirs, noMemory), isFalse, reason: status);
      }
    });

    test('a guest row is manageable only with its captured/re-entered token', () {
      final guest = _entry(id: 'g1', status: 'pending_confirmation', isGuest: true);
      expect(canConfirm(guest, noMemory), isFalse);
      expect(canConfirm(guest, {'g1': 'token'}), isTrue);
      expect(canLeave(guest, {'g1': 'token'}), isTrue);
      expect(canLeave(guest, {'other': 'token'}), isFalse);
    });

    test('an older backend without is_self degrades to "not mine", never to "mine"', () {
      final row = RosterEntry.fromRow({
        'participant_id': 'p1',
        'session_id': 's1',
        'display_name': 'X',
        'status': 'confirmed',
        'skill_level': null,
        'seconds_until_expiry': null,
        'is_guest': null,
      });
      expect(canLeave(row, noMemory), isFalse);
    });
  });

  group('hasActiveSelfEntry / occupiedSpots', () {
    test('Join is suppressed once the server reports an active self row', () {
      expect(hasActiveSelfEntry([_entry(isSelf: false), _entry(id: 'p2', isSelf: true)]), isTrue);
      expect(hasActiveSelfEntry([_entry(isSelf: false)]), isFalse);
      expect(hasActiveSelfEntry(const []), isFalse);
    });

    test('pending offers count as occupied, exactly like the server', () {
      final roster = [
        _entry(id: 'a'),
        _entry(id: 'b', status: 'pending_confirmation'),
        _entry(id: 'c', status: 'waitlisted'),
      ];
      expect(occupiedSpots(roster), 2);
    });
  });

  group('canReportOrBlock', () {
    test('offered for a registered participant (is_guest == false, e.g. organizer/staff view)', () {
      expect(
        canReportOrBlock(_entry(isGuest: false), isMine: false, isSignedIn: true),
        isTrue,
      );
    });

    test('offered when is_guest is null (the common case for an ordinary joined viewer) -- '
        'the RPC itself is the real enforcement point, not this client-side guess', () {
      expect(
        canReportOrBlock(_entry(isGuest: null), isMine: false, isSignedIn: true),
        isTrue,
      );
    });

    test('NEVER offered when the server has confirmed is_guest == true', () {
      expect(
        canReportOrBlock(_entry(isGuest: true), isMine: false, isSignedIn: true),
        isFalse,
      );
    });

    test('never offered for the viewer\'s own row, regardless of is_guest', () {
      expect(canReportOrBlock(_entry(isGuest: false), isMine: true, isSignedIn: true), isFalse);
      expect(canReportOrBlock(_entry(isGuest: null), isMine: true, isSignedIn: true), isFalse);
    });

    test('never offered to a signed-out viewer', () {
      expect(canReportOrBlock(_entry(isGuest: false), isMine: false, isSignedIn: false), isFalse);
    });
  });
}
