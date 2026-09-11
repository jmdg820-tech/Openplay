/// Mirrors the `public_profiles` view (id, name, photo_url only -- no
/// skill_level, no is_platform_admin). Used to resolve a session's
/// organizer display name without ever touching session_participants.
class PublicProfile {
  final String id;
  final String name;
  final String? photoUrl;

  PublicProfile({required this.id, required this.name, required this.photoUrl});

  factory PublicProfile.fromRow(Map<String, dynamic> row) => PublicProfile(
        id: row['id'] as String,
        name: row['name'] as String? ?? '(unknown)',
        photoUrl: row['photo_url'] as String?,
      );
}
