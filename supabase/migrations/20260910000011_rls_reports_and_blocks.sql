-- OPENPLAY MVP — 011: reports + blocks RLS

alter table reports enable row level security;
alter table reports force row level security;

create policy reports_select_own
  on reports for select
  to authenticated
  using (reporter_user_id = auth.uid());

revoke all on reports from public, anon;
grant select on reports to authenticated;
-- No INSERT grant: submission goes through submit_report(), which hosts the
-- general-report duplicate-submission check that a plain CHECK/UNIQUE
-- constraint cannot express.

alter table blocks enable row level security;
alter table blocks force row level security;

create policy blocks_select_own
  on blocks for select
  to authenticated
  using (blocker_user_id = auth.uid());

create policy blocks_insert_own
  on blocks for insert
  to authenticated
  with check (blocker_user_id = auth.uid());

create policy blocks_delete_own
  on blocks for delete
  to authenticated
  using (blocker_user_id = auth.uid());

-- Force blocker_user_id to the caller's own identity regardless of what a
-- client payload supplies -- removes any possibility of the WITH CHECK
-- above being satisfied by coincidence or client error, and means the
-- client only ever needs to send blocked_user_id.
create or replace function force_blocker_identity()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  new.blocker_user_id := auth.uid();
  return new;
end;
$$;

revoke execute on function force_blocker_identity() from public;

create trigger blocks_force_blocker_identity
  before insert on blocks
  for each row execute function force_blocker_identity();

revoke all on blocks from public, anon;
grant select, insert (blocked_user_id), delete on blocks to authenticated;
