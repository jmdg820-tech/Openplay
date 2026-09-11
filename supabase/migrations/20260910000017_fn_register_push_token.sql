-- OPENPLAY MVP — 017: register_push_token()
-- A token identifies one device installation and must belong to exactly one
-- current owner. Reassignment (a reused/shared device logging in as a
-- different account) cannot be expressed as a plain client UPDATE under
-- self-scoped RLS, because the existing row may belong to someone else --
-- this function performs the upsert as SECURITY DEFINER instead.

create or replace function register_push_token(p_token text, p_platform text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_caller uuid := auth.uid();
begin
  if v_caller is null then
    raise exception 'authentication required';
  end if;

  if p_platform not in ('ios', 'android', 'windows') then
    raise exception 'invalid platform';
  end if;

  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'a token is required';
  end if;

  insert into push_tokens (user_id, token, platform)
  values (v_caller, p_token, p_platform)
  on conflict (token) do update
    set user_id = excluded.user_id,
        platform = excluded.platform,
        updated_at = now();
end;
$$;

revoke execute on function register_push_token(text, text) from public;
grant execute on function register_push_token(text, text) to authenticated;
