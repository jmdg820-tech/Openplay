import 'package:flutter_test/flutter_test.dart';
import 'package:openplay_app/models/roster_entry.dart';
import 'package:openplay_app/utils/roster_actions.dart';

RosterEntry _entry({String status = 'confirmed', bool? isGuest}) => RosterEntry(
      participantId: 'p1',
      sessionId: 's1',
      displayName: 'Someone',
      status: status,
      skillLevel: null,
      secondsUntilExpiry: null,
      isGuest: isGuest,
    );

void main() {
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
