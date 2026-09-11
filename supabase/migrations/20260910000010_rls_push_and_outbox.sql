-- OPENPLAY MVP — 010: push_tokens + notification_outbox RLS

alter table push_tokens enable row level security;
alter table push_tokens force row level security;

create policy push_tokens_select_own
  on push_tokens for select
  to authenticated
  using (user_id = auth.uid());

create policy push_tokens_delete_own
  on push_tokens for delete
  to authenticated
  using (user_id = auth.uid());

revoke all on push_tokens from public, anon;
grant select, delete on push_tokens to authenticated;
-- No INSERT/UPDATE grant: writing (including the reassignment-on-conflict
-- case, where a device's token moves to a different account) only happens
-- via register_push_token(), which runs as SECURITY DEFINER.

alter table notification_outbox enable row level security;
alter table notification_outbox force row level security;
-- No policies for any client role -- zero access by RLS, by design.

revoke all on notification_outbox from public, anon, authenticated;
-- service_role has BYPASSRLS and full table privileges (granted generally
-- to service_role across the schema in the final setup migration).
