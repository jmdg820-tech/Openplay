-- OPENPLAY MVP — 021: Realtime publication for `sessions` only
--
-- Rule: "Realtime may be used for sessions only. Roster changes must be
-- obtained by refetching get_session_roster(). Do not attempt to expose
-- raw participant changes through Realtime."
--
-- `sessions` has no sensitive columns (see migration 008: it is already
-- fully public-readable via `sessions_select_all`), so broadcasting its
-- row-level changes (status flips to cancelled, start_time/venue changes)
-- over Realtime discloses nothing a client couldn't already SELECT, and
-- lets the app live-update a session list/detail view without polling.
--
-- `session_participants` is deliberately NEVER added to any publication:
-- migration 009 already revokes all client grants on it and leaves it with
-- zero RLS policies, so even if it were added to a publication, Realtime's
-- own RLS-aware broadcast would still emit nothing to anon/authenticated
-- subscribers -- this migration keeps it out of the publication entirely
-- as a second, independent barrier (defense in depth, same posture as
-- migration 009's belt-and-braces REVOKE alongside RLS).

-- On a real Supabase project/local CLI stack, `supabase_realtime` already
-- exists (created by the platform's own bootstrap migrations before user
-- migrations run). Guard its creation so this migration is also portable
-- to a bare Postgres instance that has no such publication yet.
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end
$$;

alter publication supabase_realtime add table public.sessions;
