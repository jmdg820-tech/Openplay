-- OPENPLAY MVP — 005: session-change notification fan-out + reminder-clear rule.
--
-- One AFTER UPDATE trigger on `sessions` handles both notification events that
-- originate from a session update (cancellation, and a time/venue edit),
-- keeping `cancel_session()` and plain organizer edits focused on the
-- authorization + write, not the notification side-effect.

create or replace function notify_session_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_event notification_event_enum;
  v_payload jsonb;
begin
  if new.status = 'cancelled' and old.status = 'active' then
    v_event := 'session_cancelled';
    v_payload := jsonb_build_object('session_id', new.id, 'reason', new.cancellation_reason);
  elsif new.status = 'active'
        and (new.start_time is distinct from old.start_time
             or new.end_time is distinct from old.end_time
             or new.venue_id is distinct from old.venue_id) then
    v_event := 'session_changed';
    v_payload := jsonb_build_object(
      'session_id', new.id,
      'start_time', new.start_time,
      'end_time', new.end_time,
      'venue_id', new.venue_id
    );

    -- Reminder idempotency fix: a reminder already enqueued for the OLD
    -- start_time is now describing the wrong time. Clear only the UNSENT
    -- one so the sweep can schedule a correctly-timed reminder later.
    -- Already-delivered reminders are left alone (not clawed back).
    if new.start_time is distinct from old.start_time then
      delete from notification_outbox
      where session_id = new.id
        and event_type = 'session_reminder'
        and sent_at is null;
    end if;
  else
    return new;
  end if;

  insert into notification_outbox (user_id, event_type, session_id, payload)
  select sp.user_id, v_event, new.id, v_payload
  from session_participants sp
  where sp.session_id = new.id
    and sp.user_id is not null
    and sp.status in ('confirmed', 'waitlisted', 'pending_confirmation');

  return new;
end;
$$;

revoke execute on function notify_session_change() from public;

create trigger sessions_notify_change
  after update on sessions
  for each row execute function notify_session_change();
