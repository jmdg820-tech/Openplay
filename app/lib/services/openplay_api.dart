// `Session` collides with this project's own `Session` (auth session vs.
// our OpenPlay session model) -- we never need gotrue's Session here.
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../models/my_participation.dart';
import '../models/public_profile.dart';
import '../models/roster_entry.dart';
import '../models/session.dart';
import '../models/venue.dart';

/// Thin wrapper around the Supabase client that is the app's ONLY point of
/// contact with the backend's approved surface: the RPCs and the public
/// tables (`venues`, `sessions`) that RLS already makes world-readable.
///
/// Deliberately absent: any `.from('session_participants')` call, anywhere.
/// The roster is fetched exclusively through [getSessionRoster], per the
/// approved architecture (session_participants has zero client grants and
/// zero RLS policies -- a direct query would just fail with "permission
/// denied", by design).
class OpenPlayApi {
  OpenPlayApi(this._client);

  final SupabaseClient _client;

  String? get currentUserId => _client.auth.currentUser?.id;
  bool get isSignedIn => _client.auth.currentUser != null;

  // ---------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------

  Future<void> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    await _client.auth.signUp(
      email: email,
      password: password,
      data: {'name': displayName},
    );
  }

  Future<void> signIn({required String email, required String password}) =>
      _client.auth.signInWithPassword(email: email, password: password);

  Future<void> signOut() => _client.auth.signOut();

  // ---------------------------------------------------------------------
  // Venues
  // ---------------------------------------------------------------------

  Future<List<Venue>> listVenues() async {
    final rows = await _client.from('venues').select().order('name');
    return rows.map(Venue.fromRow).toList();
  }

  Future<Venue> getVenue(String venueId) async {
    final row = await _client.from('venues').select().eq('id', venueId).single();
    return Venue.fromRow(row);
  }

  /// Only ever returns a boolean -- never exposes staff identities.
  Future<bool> isVenueManaged(String venueId) async {
    final result = await _client.rpc('is_venue_managed', params: {'p_venue_id': venueId});
    return result as bool;
  }

  Future<void> claimVenue(String venueId) =>
      _client.rpc('claim_venue', params: {'p_venue_id': venueId});

  /// `venues.location` is `geography(Point,4326) NOT NULL` -- there is no
  /// venue without a location. `latitude`/`longitude` are sent as WKT
  /// ('POINT(lng lat)'), which PostGIS accepts as input for a geography
  /// column; this is the standard, documented way to insert a point via
  /// PostgREST/supabase-js without a bespoke RPC (no live PostGIS backend
  /// was available in this environment to confirm end-to-end -- see the
  /// implementation report).
  Future<String> createVenue({
    required String name,
    required double latitude,
    required double longitude,
    int? numberOfCourts,
    String? addressText,
    String? hoursInfo,
  }) async {
    final row = await _client
        .from('venues')
        .insert({
          'name': name,
          'location': 'POINT($longitude $latitude)',
          'number_of_courts': numberOfCourts,
          'address_text': addressText,
          'hours_info': hoursInfo,
          'created_by': currentUserId,
        })
        .select()
        .single();
    return row['id'] as String;
  }

  // ---------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------

  Future<List<Session>> listSessions({
    String? venueId,
    DateTime? onOrAfter,
    DateTime? before,
    bool activeOnly = false,
  }) async {
    var query = _client.from('sessions').select();
    if (venueId != null) query = query.eq('venue_id', venueId);
    if (onOrAfter != null) query = query.gte('start_time', onOrAfter.toUtc().toIso8601String());
    if (before != null) query = query.lt('start_time', before.toUtc().toIso8601String());
    if (activeOnly) query = query.eq('status', 'active');
    final rows = await query.order('start_time');
    return rows.map(Session.fromRow).toList();
  }

  /// Batched organizer/venue-name lookups for discovery cards. Only ever
  /// reads `venues` (already public) and `public_profiles` (id/name/
  /// photo_url only) -- never session_participants.
  Future<Map<String, PublicProfile>> getPublicProfiles(Iterable<String> ids) async {
    final uniqueIds = ids.toSet().toList();
    if (uniqueIds.isEmpty) return {};
    final rows = await _client.from('public_profiles').select().inFilter('id', uniqueIds);
    return {for (final row in rows) row['id'] as String: PublicProfile.fromRow(row)};
  }

  Future<Map<String, Venue>> getVenuesByIds(Iterable<String> ids) async {
    final uniqueIds = ids.toSet().toList();
    if (uniqueIds.isEmpty) return {};
    final rows = await _client.from('venues').select().inFilter('id', uniqueIds);
    final venues = rows.map(Venue.fromRow);
    return {for (final v in venues) v.id: v};
  }

  Future<Session> getSession(String sessionId) async {
    final row = await _client.from('sessions').select().eq('id', sessionId).single();
    return Session.fromRow(row);
  }

  /// Live session list/detail updates. `session_participants` is never
  /// streamed -- roster changes are only ever picked up by refetching
  /// [getSessionRoster].
  Stream<List<Map<String, dynamic>>> watchSessions({String? venueId}) {
    final stream = _client.from('sessions').stream(primaryKey: ['id']);
    return venueId == null ? stream : stream.eq('venue_id', venueId);
  }

  Future<String> createSession({
    required String venueId,
    required String sessionType,
    required DateTime startTime,
    required DateTime endTime,
    required int capacity,
    String? skillLevelInfo,
  }) async {
    final row = await _client
        .from('sessions')
        .insert({
          'venue_id': venueId,
          'created_by': currentUserId,
          'session_type': sessionType,
          'start_time': startTime.toUtc().toIso8601String(),
          'end_time': endTime.toUtc().toIso8601String(),
          'capacity': capacity,
          'skill_level_info': skillLevelInfo,
        })
        .select()
        .single();
    return row['id'] as String;
  }

  Future<void> cancelSession(String sessionId, String reason) => _client.rpc(
        'cancel_session',
        params: {'p_session_id': sessionId, 'p_reason': reason},
      );

  /// Organizer/staff edit of an *active* session's own fields (time,
  /// capacity, skill info). This is a direct table UPDATE, not a bypass:
  /// it is exactly the surface migration 008's `sessions_update_own_or_staff`
  /// policy (USING organizer-or-staff, WITH CHECK status='active') and
  /// migration 005's `notify_session_change` trigger (clears only unsent
  /// reminders on a start_time change) were built for. Only `cancel_session`
  /// may ever move status to 'cancelled' -- the policy's WITH CHECK forbids
  /// a client from doing that through this path.
  Future<void> updateSession(
    String sessionId, {
    DateTime? startTime,
    DateTime? endTime,
    int? capacity,
    String? skillLevelInfo,
  }) async {
    final patch = <String, dynamic>{};
    if (startTime != null) patch['start_time'] = startTime.toUtc().toIso8601String();
    if (endTime != null) patch['end_time'] = endTime.toUtc().toIso8601String();
    if (capacity != null) patch['capacity'] = capacity;
    if (skillLevelInfo != null) patch['skill_level_info'] = skillLevelInfo;
    if (patch.isEmpty) return;
    await _client.from('sessions').update(patch).eq('id', sessionId);
  }

  // ---------------------------------------------------------------------
  // Roster -- the ONLY read surface for session_participants
  // ---------------------------------------------------------------------

  Future<List<RosterEntry>> getSessionRoster(String sessionId) async {
    final rows = await _client.rpc('get_session_roster', params: {'p_session_id': sessionId});
    return (rows as List).cast<Map<String, dynamic>>().map(RosterEntry.fromRow).toList();
  }

  /// The signed-in user's own active registrations (migration 028). Powers
  /// the in-app "you've been offered a spot" banner and My sessions. Only
  /// ever the caller's rows -- identity is auth.uid() server-side.
  Future<List<MyParticipation>> getMyParticipations() async {
    final rows = await _client.rpc('get_my_participations');
    return (rows as List).cast<Map<String, dynamic>>().map(MyParticipation.fromRow).toList();
  }

  // ---------------------------------------------------------------------
  // Join / leave / promotion
  // ---------------------------------------------------------------------

  /// Registered-user join. Returns (participantId, status); managementToken
  /// is always null for a registered join (only guests get one).
  Future<JoinResult> joinAsSelf(String sessionId) async {
    final rows = await _client.rpc('join_session', params: {'p_session_id': sessionId});
    final row = (rows as List).cast<Map<String, dynamic>>().single;
    return JoinResult.fromRow(row);
  }

  /// Guest join. The returned managementToken is the guest's ONLY way to
  /// manage their own registration afterward -- the UI must show it once,
  /// tell the guest to save it, and never assume it can be recovered.
  Future<JoinResult> joinAsGuest(
    String sessionId, {
    required String guestName,
    required String contactMethod, // 'phone' | 'email'
    required String contactValue,
  }) async {
    final rows = await _client.rpc('join_session', params: {
      'p_session_id': sessionId,
      'p_guest_name': guestName,
      'p_guest_contact_method': contactMethod,
      'p_guest_contact_value': contactValue,
    });
    final row = (rows as List).cast<Map<String, dynamic>>().single;
    return JoinResult.fromRow(row);
  }

  Future<void> leaveSession(String participantId, {String? managementToken}) => _client.rpc(
        'leave_session',
        params: {
          'p_participant_id': participantId,
          'p_management_token': ?managementToken,
        },
      );

  Future<void> confirmPromotion(String participantId, {String? managementToken}) => _client.rpc(
        'confirm_promotion',
        params: {
          'p_participant_id': participantId,
          'p_management_token': ?managementToken,
        },
      );

  /// Organizer/venue-staff removal -- no token, authorization is auth.uid()-based.
  Future<void> removeParticipant(String participantId) =>
      _client.rpc('remove_participant', params: {'p_participant_id': participantId});

  // ---------------------------------------------------------------------
  // Push tokens (registration only -- delivery worker is out of scope for
  // this client app; see final report known limitations)
  // ---------------------------------------------------------------------

  Future<void> registerPushToken(String token, String platform) => _client.rpc(
        'register_push_token',
        params: {'p_token': token, 'p_platform': platform},
      );

  // ---------------------------------------------------------------------
  // Reports & blocks
  // ---------------------------------------------------------------------

  Future<void> submitReport({
    required String reportedUserId,
    String? sessionId,
    String? reason,
  }) =>
      _client.rpc('submit_report', params: {
        'p_reported_user_id': reportedUserId,
        'p_session_id': sessionId,
        'p_reason': reason,
      });

  /// blocks has a direct (column-restricted) client grant, not an RPC --
  /// blocker_user_id is force-set server-side by a trigger regardless of
  /// what is sent here.
  Future<void> blockUser(String blockedUserId) =>
      _client.from('blocks').insert({'blocked_user_id': blockedUserId});

  Future<void> unblockUser(String blockedUserId) =>
      _client.from('blocks').delete().eq('blocked_user_id', blockedUserId);

  /// `blocks_select_own` scopes this to rows the CALLER created as blocker
  /// -- never who blocked the caller (see the security gate's "affected
  /// user" privacy case).
  Future<List<String>> listMyBlockedUserIds() async {
    final rows = await _client.from('blocks').select('blocked_user_id');
    return rows.map((r) => r['blocked_user_id'] as String).toList();
  }

  // ---------------------------------------------------------------------
  // Report/block an arbitrary ROSTER participant (migration 022)
  // ---------------------------------------------------------------------
  //
  // Both take ONLY the participant_id already present in a
  // get_session_roster() row -- never a user_id, which this client never
  // has for a roster entry in the first place. The server resolves the
  // target internally, verifies the caller is authorized for that exact
  // session, and rejects a guest target with one fixed generic message
  // (never returns which reason it failed for -- see error_messages.dart
  // for how the UI maps that without re-introducing a side channel).

  Future<String> reportParticipant(String participantId, String reason) async {
    final result = await _client.rpc('report_session_participant', params: {
      'p_participant_id': participantId,
      'p_reason': reason,
    });
    return result as String;
  }

  Future<void> blockParticipant(String participantId) => _client.rpc(
        'block_session_participant',
        params: {'p_participant_id': participantId},
      );
}

class JoinResult {
  final String participantId;
  final String status;
  final String? managementToken;

  JoinResult({required this.participantId, required this.status, required this.managementToken});

  factory JoinResult.fromRow(Map<String, dynamic> row) => JoinResult(
        participantId: row['participant_id'] as String,
        status: row['status'] as String,
        managementToken: row['management_token'] as String?,
      );
}
