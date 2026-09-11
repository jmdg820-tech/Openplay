-- OPENPLAY MVP — 002: core tables (10 total), per the approved v3 specification.

create table profiles (
  id                 uuid primary key references auth.users(id) on delete cascade,
  name               text not null,
  photo_url          text,
  skill_level        skill_level_enum,
  is_platform_admin  boolean not null default false,
  created_at         timestamptz not null default now()
);

create table venues (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  location          geography(Point, 4326) not null,
  address_text      text,
  number_of_courts  int,
  hours_info        text,
  created_by        uuid not null references profiles(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint venues_number_of_courts_check
    check (number_of_courts is null or number_of_courts >= 1)
);

create table venue_staff (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references venues(id) on delete cascade,
  user_id     uuid not null references profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  constraint venue_staff_unique unique (venue_id, user_id)
);

create table sessions (
  id                   uuid primary key default gen_random_uuid(),
  venue_id             uuid not null references venues(id),
  created_by           uuid not null references profiles(id),
  session_type         session_type_enum not null,
  start_time           timestamptz not null,
  end_time             timestamptz not null,
  capacity             int not null,
  status               session_status_enum not null default 'active',
  cancellation_reason  text,
  skill_level_info     skill_level_enum,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint sessions_time_check check (end_time > start_time),
  constraint sessions_capacity_check check (
    (session_type = 'singles' and capacity >= 2) or
    (session_type = 'doubles' and capacity >= 4)
  ),
  constraint sessions_cancellation_pairing check (
    (status = 'cancelled') = (cancellation_reason is not null)
  )
);

create table session_participants (
  id                     uuid primary key default gen_random_uuid(),
  session_id             uuid not null references sessions(id) on delete cascade,
  user_id                uuid references profiles(id),
  guest_name             text,
  management_token       uuid,
  status                 participant_status_enum not null default 'confirmed',
  joined_at              timestamptz not null default now(),
  waitlist_order_at      timestamptz not null default now(),
  promoted_at            timestamptz,
  promotion_expires_at   timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint session_participants_identity_check check (
    (user_id is not null and guest_name is null and management_token is null)
    or
    (user_id is null and guest_name is not null and management_token is not null)
  ),
  constraint session_participants_pending_pairing check (
    (status = 'pending_confirmation') = (promotion_expires_at is not null)
  )
);

-- Active-status-only uniqueness: one active participation row per registered
-- user per session; a prior left/removed row does not block rejoining.
create unique index session_participants_active_user_unique
  on session_participants (session_id, user_id)
  where user_id is not null
    and status in ('confirmed', 'waitlisted', 'pending_confirmation');

create table guest_contacts (
  participant_id   uuid primary key references session_participants(id) on delete cascade,
  contact_method   contact_method_enum not null,
  contact_value    text not null,
  created_at       timestamptz not null default now(),
  constraint guest_contacts_format_check check (
    (contact_method = 'email' and contact_value ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
    or
    (contact_method = 'phone' and contact_value ~ '^[0-9+][0-9+\-\s()]{5,}$')
  )
);

create table push_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  token       text not null,
  platform    text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint push_tokens_token_unique unique (token),
  constraint push_tokens_platform_check check (platform in ('ios', 'android', 'windows'))
);

create table notification_outbox (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  event_type  notification_event_enum not null,
  session_id  uuid references sessions(id) on delete cascade,
  payload     jsonb not null default '{}'::jsonb,
  attempts    int not null default 0,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz,
  constraint notification_outbox_attempts_check check (attempts >= 0)
);

-- Idempotency for the reminder sweep: at most one 'session_reminder' row
-- per (session, user), regardless of how many times the sweep runs.
create unique index notification_outbox_reminder_unique
  on notification_outbox (session_id, user_id)
  where event_type = 'session_reminder';

create table reports (
  id                  uuid primary key default gen_random_uuid(),
  reporter_user_id    uuid not null references profiles(id),
  reported_user_id    uuid not null references profiles(id),
  session_id          uuid references sessions(id),
  reason              text not null,
  created_at          timestamptz not null default now(),
  constraint reports_no_self_report check (reporter_user_id <> reported_user_id),
  constraint reports_session_scoped_unique unique (reporter_user_id, reported_user_id, session_id)
);

create table blocks (
  id                 uuid primary key default gen_random_uuid(),
  blocker_user_id    uuid not null references profiles(id),
  blocked_user_id    uuid not null references profiles(id),
  created_at         timestamptz not null default now(),
  constraint blocks_no_self_block check (blocker_user_id <> blocked_user_id),
  constraint blocks_unique unique (blocker_user_id, blocked_user_id)
);
