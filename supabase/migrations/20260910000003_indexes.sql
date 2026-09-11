-- OPENPLAY MVP — 003: indexes

create index venues_location_gix on venues using gist (location);
create index venues_created_by_idx on venues (created_by);

create index venue_staff_user_id_idx on venue_staff (user_id);

create index sessions_venue_id_idx on sessions (venue_id);
create index sessions_status_start_time_idx on sessions (status, start_time);
create index sessions_created_by_idx on sessions (created_by);

create index session_participants_roster_idx
  on session_participants (session_id, status, waitlist_order_at);
create index session_participants_user_id_idx
  on session_participants (user_id) where user_id is not null;
create index session_participants_pending_expiry_idx
  on session_participants (promotion_expires_at) where status = 'pending_confirmation';

create index guest_contacts_contact_lower_idx
  on guest_contacts (lower(contact_value));

create index push_tokens_user_id_idx on push_tokens (user_id);

create index notification_outbox_unsent_idx
  on notification_outbox (created_at) where sent_at is null;
create index notification_outbox_user_id_idx on notification_outbox (user_id);

create index reports_reported_user_id_idx on reports (reported_user_id);
create index reports_reporter_user_id_idx on reports (reporter_user_id);

create index blocks_blocked_user_id_idx on blocks (blocked_user_id);
