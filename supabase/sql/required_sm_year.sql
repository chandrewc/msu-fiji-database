-- Require Sigma Mu class year during self-registration and profile completion.
CREATE OR REPLACE FUNCTION public.handle_new_brother()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_username text;
  v_name text;
  v_type text;
  v_phone text;
  v_sm_year text := nullif(btrim(new.raw_user_meta_data->>'requested_sm_year'), '');
  social boolean := coalesce(new.raw_app_meta_data->>'provider', '') = 'google';
begin
  if not social and new.invited_at is null and (v_sm_year is null or v_sm_year !~ '^(19[0-9]{2}|20[0-9]{2}|21[0-9]{2}|2200)$') then
    raise exception 'Enter your four-digit Sigma Mu year';
  end if;
  if v_sm_year is not null and v_sm_year !~ '^(19[0-9]{2}|20[0-9]{2}|21[0-9]{2}|2200)$' then
    raise exception 'Enter your four-digit Sigma Mu year';
  end if;
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
    email_contact, phone_contact, pledge_class, registration_complete
  ) values (
    new.id, v_username, v_name, v_type, 'member', false, false,
    new.email, v_phone, v_sm_year, not social
  ) on conflict (user_id) do nothing;
  return new;
end;
$function$
;
drop function public.complete_brother_registration(text,text,text,text,text);
CREATE OR REPLACE FUNCTION public.complete_brother_registration(p_full_name text, p_username text, p_phone text, p_member_type text, p_email text DEFAULT NULL::text, p_sm_year text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  owner uuid := auth.uid();
  address text;
  username_value text := nullif(lower(btrim(p_username)), '');
  name_value text := btrim(p_full_name);
  phone_value text := btrim(p_phone);
  sm_year_value text := btrim(p_sm_year);
  existing_username text;
begin
  if owner is null then
    raise exception 'Sign in first';
  end if;
  select username into existing_username from public.members
  where user_id = owner and not approved and not rejected
    and not registration_complete and role = 'member' and deactivated_at is null
  for update;
  if not found then
    raise exception 'Registration is not available for this account';
  end if;
  if name_value is null or length(name_value) not between 2 and 120 then
    raise exception 'Enter your full name';
  end if;
  if sm_year_value is null or sm_year_value !~ '^(19[0-9]{2}|20[0-9]{2}|21[0-9]{2}|2200)$' then
    raise exception 'Enter your four-digit Sigma Mu year';
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
    if existing_username ~ '^pending_[0-9a-f]{32}$' then
      username_value := private.generate_brother_username(name_value, owner);
    else
      username_value := existing_username;
    end if;
  end if;
  update public.members set
    full_name = name_value,
    username = username_value,
    phone_contact = phone_value,
    member_type = p_member_type,
    email_contact = address,
    pledge_class = sm_year_value,
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
$function$
;
revoke all on function public.complete_brother_registration(text,text,text,text,text,text) from public,anon;
grant execute on function public.complete_brother_registration(text,text,text,text,text,text) to authenticated;
CREATE OR REPLACE FUNCTION public.review_brother_application(p_user_id uuid, p_approve boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null or not public.has_admin_permission('requests') then raise exception 'Membership requests permission required'; end if;
 if p_user_id=auth.uid() then raise exception 'Cannot review own application'; end if;
 if p_approve and exists(select 1 from public.members where user_id=p_user_id and (not registration_complete or pledge_class is null or btrim(pledge_class) !~ '^(19[0-9]{2}|20[0-9]{2}|21[0-9]{2}|2200)$')) then raise exception 'Brother must complete registration with their Sigma Mu year before approval'; end if;
 update public.members set approved=p_approve,rejected=not p_approve,updated_at=now() where user_id=p_user_id and role='member' and approved=false and deactivated_at is null;
 if not found then raise exception 'Application not reviewable'; end if;
end $function$
;
-- Existing pending requests complete their year before approval.
update public.members set registration_complete=false
where not approved and not rejected and deactivated_at is null and role='member'
  and (pledge_class is null or btrim(pledge_class) !~ '^(19[0-9]{2}|20[0-9]{2}|21[0-9]{2}|2200)$');
notify pgrst, 'reload schema';
