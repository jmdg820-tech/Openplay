-- OPENPLAY MVP — 007: venues + venue_staff RLS
--
-- `venues` has no sensitive columns at all, so the raw table itself is the
-- public surface (no view needed). `venue_staff` is different: even though
-- it only holds id pairs, it exposes a user-venue relationship with no
-- stated product need to be public, so raw SELECT is restricted to a
-- venue's own current staff; the public surface is the is_venue_managed()
-- function defined later, returning only a boolean.
--
-- Membership checks go through is_venue_staff_member(), a SECURITY DEFINER
-- helper, rather than a direct correlated subquery against venue_staff.
-- This is required, not stylistic: venue_staff's OWN select policy also
-- needs to check membership in venue_staff, and a policy that queries its
-- own table directly causes Postgres to re-evaluate that same policy for
-- the subquery, which re-triggers the subquery, infinitely ("infinite
-- recursion detected in policy for relation venue_staff"). Routing the
-- check through a SECURITY DEFINER function breaks the cycle: the
-- function's internal query runs under the function owner's bypassed-RLS
-- privilege, not the querying role's, so it never re-enters any policy.
--
-- The function takes ONLY p_venue_id and derives the actor from auth.uid()
-- internally (never a caller-supplied user id): it is GRANTed directly to
-- anon/authenticated (required so RLS policies can invoke it as the
-- querying role), so accepting an arbitrary p_user_id argument would let
-- any authenticated client call it directly to probe "is user X staff at
-- venue Y?" for arbitrary third-party X -- an information-disclosure hole.
-- Deriving identity from auth.uid() closes that off while every real call
-- site (below, and in migration 008) still gets exactly the same answer,
-- since they always meant "is the CURRENT user staff here".

create or replace function is_venue_staff_member(p_venue_id uuid)
returns boolean
language sql
security definer
set search_path = pg_catalog, public
stable
as $$
  select exists (
    select 1 from venue_staff where venue_id = p_venue_id and user_id = auth.uid()
  );
$$;

revoke execute on function is_venue_staff_member(uuid) from public;
grant execute on function is_venue_staff_member(uuid) to anon, authenticated;

alter table venues enable row level security;
alter table venues force row level security;

create policy venues_select_all
  on venues for select
  to anon, authenticated
  using (true);

create policy venues_insert_own
  on venues for insert
  to authenticated
  with check (created_by = auth.uid());

create policy venues_update_own_or_staff
  on venues for update
  to authenticated
  using (
    created_by = auth.uid()
    or is_venue_staff_member(venues.id)
  );

grant select on venues to anon, authenticated;
grant insert (name, location, address_text, number_of_courts, hours_info, created_by) on venues to authenticated;
grant update (name, location, address_text, number_of_courts, hours_info) on venues to authenticated;

alter table venue_staff enable row level security;
alter table venue_staff force row level security;

create policy venue_staff_select_own_venue_staff
  on venue_staff for select
  to authenticated
  using (is_venue_staff_member(venue_staff.venue_id));

-- Adding a FURTHER staff member (by an existing staff member) is a plain,
-- non-racy permission check -- no lock needed, unlike the first claim
-- (which goes through claim_venue(), a SECURITY DEFINER function that
-- bypasses this policy entirely via elevated privilege).
create policy venue_staff_insert_by_existing_staff
  on venue_staff for insert
  to authenticated
  with check (is_venue_staff_member(venue_staff.venue_id));

create policy venue_staff_delete_by_existing_staff
  on venue_staff for delete
  to authenticated
  using (is_venue_staff_member(venue_staff.venue_id));

grant select, insert (venue_id, user_id), delete on venue_staff to authenticated;
