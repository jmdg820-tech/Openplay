-- OPENPLAY MVP — 009: session_participants + guest_contacts RLS
--
-- Per the v3 security review's final revision: NO client role (anon,
-- authenticated -- including the participant themselves, the organizer, or
-- venue staff) has any raw grant on session_participants. The ONLY read
-- surface is get_session_roster(); the ONLY write surfaces are
-- join_session()/leave_session()/confirm_promotion()/remove_participant(),
-- all SECURITY DEFINER. This is deliberately stricter than a same-row/
-- same-session RLS policy would be, because it also closes the Realtime/
-- raw-column exposure path (management_token, waitlist_order_at,
-- promotion_expires_at) that a permissive raw policy would otherwise open.

alter table session_participants enable row level security;
alter table session_participants force row level security;
-- No policies created for anon/authenticated -- RLS enabled with zero
-- permissive policies denies all access by default for those roles. The
-- table-level REVOKE below is a second, independent barrier (defense in
-- depth against a future accidental GRANT, per the "no bypass" requirement).

revoke all on session_participants from public, anon, authenticated;

-- guest_contacts' own SELECT policy needs to know which session a given
-- participant row belongs to, and whether the viewer organizes/staffs that
-- session -- which means reading session_participants and sessions. Since
-- session_participants grants nothing at all to authenticated (above), a
-- direct correlated subquery from the guest_contacts policy would fail with
-- "permission denied for table session_participants" the moment it's
-- evaluated for that role. A SECURITY DEFINER helper performs the lookup
-- with the function owner's (bypassed-RLS) privilege instead, exactly the
-- same pattern used for is_venue_staff_member() and for the same reason.
--
-- Takes ONLY p_participant_id and derives the actor from auth.uid()
-- internally, same rationale as is_venue_staff_member(): it is GRANTed
-- directly to authenticated, so a caller-supplied p_user_id argument would
-- let any authenticated client ask "can user X manage participant Y?" for
-- an arbitrary third-party X -- an information-disclosure hole this closes.
create or replace function can_manage_session_participant(p_participant_id uuid)
returns boolean
language sql
security definer
set search_path = pg_catalog, public
stable
as $$
  select exists (
    select 1
    from session_participants sp
    join sessions s on s.id = sp.session_id
    where sp.id = p_participant_id
      and (s.created_by = auth.uid() or is_venue_staff_member(s.venue_id))
  );
$$;

revoke execute on function can_manage_session_participant(uuid) from public;
grant execute on function can_manage_session_participant(uuid) to authenticated;

alter table guest_contacts enable row level security;
alter table guest_contacts force row level security;

create policy guest_contacts_select_organizer_or_staff
  on guest_contacts for select
  to authenticated
  using (can_manage_session_participant(guest_contacts.participant_id));

revoke all on guest_contacts from public, anon;
grant select on guest_contacts to authenticated; -- narrowed to organizer/venue-staff rows only by the policy above
-- No client INSERT/UPDATE/DELETE -- guest_contacts rows are written only by
-- join_session() as SECURITY DEFINER.
