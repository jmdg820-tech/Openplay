import 'package:flutter_test/flutter_test.dart';
import 'package:openplay_app/models/public_profile.dart';
import 'package:openplay_app/models/roster_entry.dart';
import 'package:openplay_app/models/session.dart';
import 'package:openplay_app/models/venue.dart';

void main() {
  group('RosterEntry.fromRow', () {
    test('parses exactly the 7 approved columns get_session_roster() returns', () {
      final entry = RosterEntry.fromRow({
        'participant_id': 'p1',
        'session_id': 's1',
        'display_name': 'Player B',
        'status': 'confirmed',
        'skill_level': 'advanced',
        'seconds_until_expiry': null,
        'is_guest': false,
      });
      expect(entry.participantId, 'p1');
      expect(entry.sessionId, 's1');
      expect(entry.displayName, 'Player B');
      expect(entry.status, 'confirmed');
      expect(entry.skillLevel, 'advanced');
      expect(entry.secondsUntilExpiry, isNull);
      expect(entry.isGuest, false);
    });

    test('keeps is_guest as a real null (server-hidden) rather than defaulting to false', () {
      final entry = RosterEntry.fromRow({
        'participant_id': 'p1',
        'session_id': 's1',
        'display_name': 'Anonymous Player',
        'status': 'confirmed',
        'skill_level': null,
        'seconds_until_expiry': null,
        'is_guest': null,
      });
      expect(entry.isGuest, isNull, reason: 'null must stay null, not be coerced to false');
    });

    test('falls back to a placeholder display name if somehow missing', () {
      final entry = RosterEntry.fromRow({
        'participant_id': 'p1',
        'session_id': 's1',
        'display_name': null,
        'status': 'waitlisted',
        'skill_level': null,
        'seconds_until_expiry': null,
        'is_guest': true,
      });
      expect(entry.displayName, '(unknown)');
    });
  });

  group('Session.fromRow', () {
    test('parses all fields and computes isCancelled correctly', () {
      final active = Session.fromRow({
        'id': 's1',
        'venue_id': 'v1',
        'created_by': 'u1',
        'session_type': 'doubles',
        'start_time': '2026-09-10T10:00:00Z',
        'end_time': '2026-09-10T11:30:00Z',
        'capacity': 4,
        'status': 'active',
        'cancellation_reason': null,
        'skill_level_info': 'Intermediate+',
      });
      expect(active.isCancelled, isFalse);
      expect(active.capacity, 4);
      expect(active.endTime.isAfter(active.startTime), isTrue);

      final cancelled = Session.fromRow({
        'id': 's2',
        'venue_id': 'v1',
        'created_by': 'u1',
        'session_type': 'singles',
        'start_time': '2026-09-10T10:00:00Z',
        'end_time': '2026-09-10T11:00:00Z',
        'capacity': 2,
        'status': 'cancelled',
        'cancellation_reason': 'Rain',
        'skill_level_info': null,
      });
      expect(cancelled.isCancelled, isTrue);
      expect(cancelled.cancellationReason, 'Rain');
    });
  });

  group('Venue.fromRow', () {
    test('parses fields and attempts location parsing without throwing', () {
      final venue = Venue.fromRow({
        'id': 'v1',
        'name': 'Downtown Courts',
        'address_text': '123 Main St',
        'number_of_courts': 4,
        'hours_info': '6am-10pm',
        'created_by': 'u1',
        'location': {
          'type': 'Point',
          'coordinates': [121.05, 14.55],
        },
      });
      expect(venue.name, 'Downtown Courts');
      expect(venue.coordinates, isNotNull);
      expect(venue.coordinates!.lat, 14.55);
    });

    test('degrades to null coordinates for unparseable location, never throws', () {
      final venue = Venue.fromRow({
        'id': 'v1',
        'name': 'Mystery Courts',
        'address_text': null,
        'number_of_courts': null,
        'hours_info': null,
        'created_by': 'u1',
        'location': '0101000020E6100000...',
      });
      expect(venue.coordinates, isNull);
    });
  });

  group('PublicProfile.fromRow', () {
    test('parses id/name/photo_url only', () {
      final p = PublicProfile.fromRow({'id': 'u1', 'name': 'Organizer O', 'photo_url': null});
      expect(p.id, 'u1');
      expect(p.name, 'Organizer O');
      expect(p.photoUrl, isNull);
    });
  });
}
