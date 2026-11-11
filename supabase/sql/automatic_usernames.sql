-- Allocate usernames inside trusted registration functions. Existing accounts are preserved.
create or replace function private.generate_brother_username(
  p_full_name text,
  p_user_id uuid
) returns text
language plpgsql
set search_path = ''
as $$
declare
  name_parts text[];
  normalized_name text;
  first_name text;
  last_name text;
  base_name text;
  candidate text;
  suffix bigint := 1;
begin
  -- All supported registration paths use this transaction lock before choosing a name.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('brother-member-username', 0));
  normalized_name := lower(normalize(btrim(coalesce(p_full_name, '')), NFKD));
  normalized_name := regexp_replace(normalized_name, U&'[\0300-\036f]', '', 'g');
  normalized_name := regexp_replace(normalized_name, '[[:space:]]+(jr\.?|sr\.?|ii|iii|iv|v)$', '', 'i');
  name_parts := regexp_split_to_array(normalized_name, '[[:space:]]+');
  first_name := regexp_replace(name_parts[1], '[^a-z0-9]', '', 'g');
  last_name := regexp_replace(name_parts[array_length(name_parts, 1)], '[^a-z0-9]', '', 'g');
  base_name := first_name;
  if array_length(name_parts, 1) > 1 and last_name <> '' then
    base_name := concat_ws('.', nullif(first_name, ''), last_name);
  end if;
  if length(coalesce(base_name, '')) < 3 then
    base_name := concat_ws('.', 'brother', nullif(base_name, ''));
  end if;
  base_name := left(base_name, 32);
  candidate := base_name;
  while exists (
    select 1 from public.members
    where username = candidate and user_id <> p_user_id
  ) loop
    suffix := suffix + 1;
    candidate := left(base_name, 40 - length(suffix::text)) || suffix::text;
  end loop;
  return candidate;
end;
$$;
revoke all on function private.generate_brother_username(text, uuid) from public, anon, authenticated;

create or replace function public.handle_new_brother()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_username text;
  v_name text;
  v_type text;
  v_phone text;
  social boolean := coalesce(new.raw_app_meta_data->>'provider', '') = 'google';
begin
  -- Keep older clients and invitations compatible with their explicit usernames.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('brother-member-username', 0));
  v_name := coalesce(
    nullif(btrim(new.raw_user_meta_data->>'full_name'), ''),
    nullif(btrim(new.raw_user_meta_data->>'name'), ''),
    nullif(new.raw_user_meta_data->>'requested_username', ''),
    nullif(new.raw_user_meta_data->>'username', ''),
    split_part(coalesce(new.email, ''), '@', 1)
  );
  if social then
    v_username := 'pending_' || replace(new.id::text, '-', '');
  else
    v_username := lower(coalesce(
      nullif(new.raw_user_meta_data->>'requested_username', ''),
      nullif(new.raw_user_meta_data->>'username', '')
    ));
    if v_username is null then
      v_username := private.generate_brother_username(v_name, new.id);
    end if;
  end if;
  v_type := case
    when coalesce(new.raw_user_meta_data->>'requested_member_type', new.raw_user_meta_data->>'member_type') in ('active', 'graduate')
    then coalesce(new.raw_user_meta_data->>'requested_member_type', new.raw_user_meta_data->>'member_type')
    else 'graduate'
  end;
  v_phone := nullif(btrim(coalesce(new.raw_user_meta_data->>'phone_contact', '')), '');
  if v_username !~ '^[a-z0-9._-]{3,40}$' then
    raise exception 'Invalid signup username';
  end if;
  if v_phone is not null and (
    length(v_phone) > 30 or v_phone !~ '^[+0-9 ()-]+$'
    or length(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 10
  ) then
    raise exception 'Invalid phone number';
  end if;
  insert into public.members (
    user_id, username, full_name, member_type, role, approved, rejected,
    email_contact, phone_contact, registration_complete
  ) values (
    new.id, v_username, v_name, v_type, 'member', false, false,
    new.email, v_phone, not social
  ) on conflict (user_id) do nothing;
  return new;
end;
$$;
revoke all on function public.handle_new_brother() from public, anon, authenticated;

create or replace function public.complete_brother_registration(
  p_full_name text,
  p_username text,
  p_phone text,
  p_member_type text,
  p_email text default null::text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner uuid := auth.uid();
  address text;
  username_value text := nullif(lower(btrim(p_username)), '');
  name_value text := btrim(p_full_name);
  phone_value text := btrim(p_phone);
begin
  if owner is null then
    raise exception 'Sign in first';
  end if;
  perform 1 from public.members
  where user_id = owner and not approved and not rejected
    and not registration_complete and role = 'member' and deactivated_at is null
  for update;
  if not found then
    raise exception 'Registration is not available for this account';
  end if;
  if name_value is null or length(name_value) not between 2 and 120 then
    raise exception 'Enter your full name';
  end if;
  if username_value is not null and username_value !~ '^[a-z0-9._-]{3,40}$' then
    raise exception 'Use 3–40 letters, numbers, dots, underscores or hyphens for your username';
  end if;
  if phone_value is null or length(phone_value) > 30
    or phone_value !~ '^[+0-9 ()-]+$'
    or length(regexp_replace(phone_value, '[^0-9]', '', 'g')) not between 10 and 15 then
    raise exception 'Enter a valid phone number';
  end if;
  if p_member_type is null or p_member_type not in ('active', 'graduate') then
    raise exception 'Choose Active or Graduate Brother';
  end if;
  select coalesce(nullif(email, ''), nullif(btrim(p_email), '')) into address
  from auth.users where id = owner;
  if address is null or address !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Enter a valid contact email';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('brother-member-username', 0));
  if username_value is null then
    username_value := private.generate_brother_username(name_value, owner);
  end if;
  update public.members set
    full_name = name_value,
    username = username_value,
    phone_contact = phone_value,
    member_type = p_member_type,
    email_contact = address,
    registration_complete = true,
    updated_at = now()
  where user_id = owner and not approved and not rejected
    and not registration_complete and role = 'member' and deactivated_at is null;
  if not found then
    raise exception 'Registration already submitted';
  end if;
exception when unique_violation then
  raise exception 'That username is already taken. Choose another.';
end;
$$;
revoke all on function public.complete_brother_registration(text,text,text,text,text) from public, anon;
grant execute on function public.complete_brother_registration(text,text,text,text,text) to authenticated;
