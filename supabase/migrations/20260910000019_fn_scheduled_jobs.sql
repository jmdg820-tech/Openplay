-- OPENPLAY MVP — 019: scheduled-job logic (expiry sweep, reminder sweep)
--
-- These functions implement the BUSINESS LOGIC for the two required
-- scheduled jobs. Actually wiring them to a scheduler (pg_cron inside the
-- Supabase project, or a Supabase Scheduled Edge Function) is a deployment-
-- time configuration step, not a schema concern, and is explicitly deferred
-- -- documented here rather than faked. Both functions are fully real and
-- directly callable/testable right now.

create or replace function expire_pending_promotions()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_row record;
  v_count int := 0;
begin
  for v_row in
    select sp.id, sp.session_id
    from session_participants sp
    join sessions s on s.id = sp.session_id
    where sp.status = 'pending_confirmation'
      and sp.promotion_expires_at < now()
      and s.status = 'active'
  loop
    -- Lock the session first; this serializes against a concurrent
    -- confirm_promotion() for the very same row (scenario: a participant
    -- confirms at the instant their window expires).
    perform 1 from sessions where id = v_row.session_id for update;

    update session_participants
      set status = 'waitlisted',
          promotion_expires_at = null,
          waitlist_order_at = now()  -- re-queue to the BACK of the line, not
                                      -- the original joined_at position --
                                      -- otherwise this same person would be
                                      -- immediately re-selected as "earliest"
                                      -- on the very next promotion attempt.
      where id = v_row.id
        and status = 'pending_confirmation'
        and promotion_expires_at < now();

    if found then
      v_count := v_count + 1;
      perform promote_next_waitlisted(v_row.session_id);
    end if;
    -- If not found: a concurrent confirm_promotion() won the race for this
    -- row between the loop's SELECT and this UPDATE -- correctly skipped.
  end loop;

  return v_count;
end;
$$;

revoke execute on function expire_pending_promotions() from public;
grant execute on function expire_pending_promotions() to service_role;

create or replace function enqueue_session_reminders(p_window_minutes int default 90)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_count int;
begin
  insert into notification_outbox (user_id, event_type, session_id, payload)
  select sp.user_id, 'session_reminder', s.id,
         jsonb_build_object('session_id', s.id, 'start_time', s.start_time)
  from sessions s
  join session_participants sp on sp.session_id = s.id
  where s.status = 'active'
    and sp.status = 'confirmed'
    and sp.user_id is not null
    and s.start_time between now() and now() + (p_window_minutes || ' minutes')::interval
  on conflict (session_id, user_id) where event_type = 'session_reminder' do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function enqueue_session_reminders(int) from public;
grant execute on function enqueue_session_reminders(int) to service_role;

-- ============================================================================
-- DEFERRED, DOCUMENTED, NOT FAKED:
-- Scheduling these two functions (e.g. "run expire_pending_promotions() every
-- minute", "run enqueue_session_reminders() every 10 minutes") requires
-- either the pg_cron extension enabled on the target Supabase project, or a
-- Supabase Scheduled Edge Function calling them via RPC on a timer. Neither
-- is configured by this migration set -- that is real project/infrastructure
-- configuration against a live Supabase project, which is out of scope here
-- (no cloud project exists yet, per the standing instruction not to create
-- one without separate approval). The automated tests in this repository
-- call these two functions directly rather than waiting for a scheduler, and
-- that is explicitly how they are verified at this stage.
--
-- Outbox delivery (actually sending a push via APNs/FCM/Windows push,
-- reading unsent notification_outbox rows) is Phase-next application code,
-- not database schema, and is not implemented here -- also documented, not
-- faked with a stub "notification worker".
-- ============================================================================
