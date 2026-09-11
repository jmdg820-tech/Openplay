/// Mirrors the server's `sessions_capacity_check` CHECK constraint
/// (`supabase/migrations/20260910000002_tables.sql`) purely for a friendly
/// client-side error message before submitting -- the database constraint
/// is the real, only authority; this can never be looser than it, and if
/// it's ever wrong the insert still fails safely server-side.
int minCapacityFor(String sessionType) => sessionType == 'singles' ? 2 : 4;

/// Capacity does NOT have to be a multiple of the game size (2 for singles,
/// 4 for doubles) -- only >= the minimum. Returns null if valid, else a
/// user-facing message.
String? validateCapacity(String sessionType, int? capacity) {
  if (capacity == null) return 'Enter a capacity.';
  final min = minCapacityFor(sessionType);
  if (capacity < min) {
    return '$sessionType sessions need a capacity of at least $min.';
  }
  return null;
}
