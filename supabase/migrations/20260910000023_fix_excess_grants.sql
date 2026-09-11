-- OPENPLAY MVP — 023: restore intended grants (close TRUNCATE/excess-privilege gap)
--
-- Live verification against the real Supabase project found that several
-- tables carry far broader anon/authenticated privileges than intended --
-- including TRUNCATE, which is NOT subject to RLS at all. Root cause: some
-- migrations' `revoke all ... from public, anon` omitted `authenticated`
-- (guest_contacts, push_tokens, blocks, reports), and two tables
-- (sessions, venues/venue_staff) never had a `revoke all` at all, so
-- Supabase's platform-default grant on newly created public tables was
-- never removed.
--
-- This migration ONLY corrects grants. It does not touch table structure,
-- RLS policies, or any function's business logic -- every policy and
-- SECURITY DEFINER function created in prior migrations is left exactly as
-- it was; this migration purely makes the already-documented intent (each
-- grant below matches what the original migration's own comments already
-- said) actually hold at the privilege-system level.

revoke all on sessions from anon, authenticated;
grant select on sessions to anon, authenticated;
grant insert (venue_id, created_by, session_type, start_time, end_time, capacity, skill_level_info) on sessions to authenticated;
grant update (venue_id, session_type, start_time, end_time, capacity, skill_level_info) on sessions to authenticated;

revoke all on venues from anon, authenticated;
grant select on venues to anon, authenticated;
grant insert (name, location, address_text, number_of_courts, hours_info, created_by) on venues to authenticated;
grant update (name, location, address_text, number_of_courts, hours_info) on venues to authenticated;

revoke all on venue_staff from anon, authenticated;
grant select, insert (venue_id, user_id), delete on venue_staff to authenticated;

revoke all on guest_contacts from authenticated;
grant select on guest_contacts to authenticated;

revoke all on push_tokens from authenticated;
grant select, delete on push_tokens to authenticated;

revoke all on blocks from authenticated;
grant select, insert (blocked_user_id), delete on blocks to authenticated;

revoke all on reports from authenticated;
grant select on reports to authenticated;

revoke all on public_profiles from anon, authenticated;
grant select on public_profiles to anon, authenticated;
