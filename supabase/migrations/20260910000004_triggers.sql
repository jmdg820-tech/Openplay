-- OPENPLAY MVP — 004: generic updated_at trigger + profile-creation trigger

create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger venues_set_updated_at
  before update on venues
  for each row execute function set_updated_at();

create trigger sessions_set_updated_at
  before update on sessions
  for each row execute function set_updated_at();

create trigger session_participants_set_updated_at
  before update on session_participants
  for each row execute function set_updated_at();

create trigger push_tokens_set_updated_at
  before update on push_tokens
  for each row execute function set_updated_at();

-- Standard Supabase pattern: create a profiles row whenever a new auth.users
-- row is inserted. Runs as the function owner (SECURITY DEFINER) since the
-- inserting context is the auth service, not an authenticated app user.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', 'New Player'));
  return new;
end;
$$;

revoke execute on function handle_new_user() from public;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();
