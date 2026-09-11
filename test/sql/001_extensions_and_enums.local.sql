-- LOCAL TEST VARIANT of supabase/migrations/20260910000001_extensions_and_enums.sql
-- Differs from the real migration ONLY by omitting `create extension postgis`,
-- which cannot be installed on this machine without admin elevation (see the
-- final report). Used by the local test runner in place of the real file for
-- migration 001 ONLY; every other migration is applied verbatim.

create extension if not exists pgcrypto;

create type skill_level_enum as enum ('beginner', 'intermediate', 'advanced');
create type session_type_enum as enum ('singles', 'doubles');
create type session_status_enum as enum ('active', 'cancelled');
create type participant_status_enum as enum ('confirmed', 'waitlisted', 'pending_confirmation', 'left', 'removed');
create type contact_method_enum as enum ('phone', 'email');
create type notification_event_enum as enum ('join_confirmed', 'session_changed', 'session_cancelled', 'waitlist_promoted', 'session_reminder');
