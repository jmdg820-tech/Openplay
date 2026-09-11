-- ============================================================================
-- OPENPLAY — LOCAL TEST HARNESS ONLY. DO NOT APPLY TO A REAL SUPABASE PROJECT.
-- ============================================================================
-- A real Supabase project already provides: the `auth` schema, `auth.users`,
-- `auth.uid()`, and the anon/authenticated/service_role Postgres roles.
-- This file recreates just enough of that surface, with matching behavior,
-- so the real migrations in supabase/migrations/ can be applied and tested
-- against a plain local Postgres instance unmodified.

create schema if not exists auth;

create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  phone text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Matches the real Supabase auth.uid() implementation: reads the `sub` claim
-- that PostgREST attaches to the session per-request. In this harness, tests
-- set it directly via `select set_config('request.jwt.claims', ..., true)`.
create or replace function auth.uid() returns uuid
language sql stable
as $$
  select
    coalesce(
      current_setting('request.jwt.claim.sub', true),
      (current_setting('request.jwt.claims', true)::jsonb ->> 'sub')
    )::uuid
$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
  -- login roles the test runner actually connects as, each inheriting the
  -- corresponding Supabase-style privilege role (mirrors how PostgREST's
  -- `authenticator` role switches into anon/authenticated/service_role)
  if not exists (select 1 from pg_roles where rolname = 'test_anon') then
    create role test_anon login password 'test' in role anon;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'test_authenticated') then
    create role test_authenticated login password 'test' in role authenticated;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'test_service') then
    create role test_service login password 'test' in role service_role;
  end if;
end
$$;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth to anon, authenticated, service_role;
