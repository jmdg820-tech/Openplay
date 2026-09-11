-- OPENPLAY MVP — 008: sessions RLS
--
-- Sessions have no sensitive columns -- fully public, raw table is the
-- surface. Ordinary edits (time/venue/capacity) go through a plain,
-- RLS-checked UPDATE by the organizer or venue staff. Cancellation is
-- reserved exclusively for the cancel_session() RPC: the UPDATE policy's
-- WITH CHECK requires the row to remain 'active', so a raw client UPDATE
-- can never flip status to 'cancelled' -- only cancel_session(), running
-- as SECURITY DEFINER, can make that specific transition.

alter table sessions enable row level security;
alter table sessions force row level security;

create policy sessions_select_all
  on sessions for select
  to anon, authenticated
  using (true);

create policy sessions_insert_own
  on sessions for insert
  to authenticated
  with check (created_by = auth.uid());

create policy sessions_update_own_or_staff
  on sessions for update
  to authenticated
  using (
    status = 'active'
    and (
      created_by = auth.uid()
      or is_venue_staff_member(sessions.venue_id)
    )
  )
  with check (status = 'active');

grant select on sessions to anon, authenticated;
grant insert (venue_id, created_by, session_type, start_time, end_time, capacity, skill_level_info) on sessions to authenticated;
grant update (venue_id, session_type, start_time, end_time, capacity, skill_level_info) on sessions to authenticated;
