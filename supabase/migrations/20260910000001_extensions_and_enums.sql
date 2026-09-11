-- OPENPLAY MVP — 001: extensions and enum types
-- Supabase-target migration. Assumes the standard Supabase project already
-- provides: auth schema/auth.users, anon/authenticated/service_role roles,
-- pgcrypto (for gen_random_uuid()), and the postgis extension available to enable.

create extension if not exists pgcrypto;
create extension if not exists postgis;

create type skill_level_enum as enum ('beginner', 'intermediate', 'advanced');
create type session_type_enum as enum ('singles', 'doubles');
create type session_status_enum as enum ('active', 'cancelled');
create type participant_status_enum as enum ('confirmed', 'waitlisted', 'pending_confirmation', 'left', 'removed');
create type contact_method_enum as enum ('phone', 'email');
create type notification_event_enum as enum ('join_confirmed', 'session_changed', 'session_cancelled', 'waitlist_promoted', 'session_reminder');
