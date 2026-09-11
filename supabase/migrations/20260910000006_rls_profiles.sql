-- OPENPLAY MVP — 006: profiles RLS + public-safe view
--
-- Raw `profiles` is self-only. Nobody else — not anon, not authenticated
-- non-owners, not organizer/venue-staff — reads the raw table. The only
-- public surface is `public_profiles`, a fixed 3-column projection that
-- structurally cannot expose skill_level or is_platform_admin: those columns
-- simply are not in its SELECT list, so no grant mistake can leak them.

alter table profiles enable row level security;
alter table profiles force row level security;

revoke all on profiles from public, anon, authenticated;

create policy profiles_select_own
  on profiles for select
  to authenticated
  using (id = auth.uid());

create policy profiles_update_own
  on profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

grant select on profiles to authenticated;
-- Column-restricted UPDATE: a user can edit their own display fields, but
-- can never set is_platform_admin on themselves even though the row is
-- otherwise their own — that column is writable only via service_role.
grant update (name, photo_url, skill_level) on profiles to authenticated;

-- Plain view (security_invoker = false is the Postgres default as of the
-- version this targets) — it runs with its owner's privileges against the
-- now-locked-down base table, then re-exposes only these three columns to
-- anyone granted SELECT on the view itself. There is no column a caller can
-- request from this view beyond what's listed here; it is not `select *`.
create view public_profiles as
  select id, name, photo_url
  from profiles;

grant select on public_profiles to anon, authenticated;
