-- Existing members remain complete. New Google identities must submit their profile.
alter table public.members add column registration_complete boolean not null default true;
create or replace function public.handle_new_brother() returns trigger language plpgsql security definer set search_path='' as $$
declare v_username text; v_name text; v_type text; v_phone text; social boolean:=coalesce(new.raw_app_meta_data->>'provider','')='google';
begin
 if social then
  v_username:='pending_'||replace(new.id::text,'-','');
 else
  v_username:=lower(coalesce(nullif(new.raw_user_meta_data->>'requested_username',''),nullif(new.raw_user_meta_data->>'username',''),split_part(coalesce(new.email,''),'@',1)));
 end if;
 v_name:=coalesce(nullif(new.raw_user_meta_data->>'full_name',''),nullif(new.raw_user_meta_data->>'name',''),v_username);
 v_type:=case when coalesce(new.raw_user_meta_data->>'requested_member_type',new.raw_user_meta_data->>'member_type') in ('active','graduate') then coalesce(new.raw_user_meta_data->>'requested_member_type',new.raw_user_meta_data->>'member_type') else 'graduate' end;
 v_phone:=nullif(btrim(coalesce(new.raw_user_meta_data->>'phone_contact','')),'');
 if v_username !~ '^[a-z0-9._-]{3,40}$' then raise exception 'Invalid signup username'; end if;
 if v_phone is not null and (length(v_phone)>30 or v_phone !~ '^[+0-9 ()-]+$' or length(regexp_replace(v_phone,'[^0-9]','','g'))<10) then raise exception 'Invalid phone number'; end if;
 insert into public.members(user_id,username,full_name,member_type,role,approved,rejected,email_contact,phone_contact,registration_complete)
 values(new.id,v_username,v_name,v_type,'member',false,false,new.email,v_phone,not social) on conflict(user_id) do nothing;
 return new;
end $$;
revoke execute on function public.handle_new_brother() from public,anon,authenticated;

-- Narrow RPC because pending profiles cannot use the approved-member UPDATE policy.
-- Never accepts role, approval, rejection or another user's ID.
create function public.complete_brother_registration(p_full_name text,p_username text,p_phone text,p_member_type text,p_email text default null)
returns void language plpgsql security definer set search_path='' as $$
declare owner uuid:=auth.uid(); address text; username_value text:=lower(btrim(p_username)); name_value text:=btrim(p_full_name); phone_value text:=btrim(p_phone);
begin
 if owner is null then raise exception 'Sign in first'; end if;
 if not exists(select 1 from public.members where user_id=owner and not approved and not rejected and not registration_complete and role='member') then raise exception 'Registration is not available for this account'; end if;
 if name_value is null or length(name_value) not between 2 and 120 then raise exception 'Enter your full name'; end if;
 if username_value is null or username_value !~ '^[a-z0-9._-]{3,40}$' then raise exception 'Use 3–40 letters, numbers, dots, underscores or hyphens for your username'; end if;
 if phone_value is null or length(phone_value)>30 or phone_value !~ '^[+0-9 ()-]+$' or length(regexp_replace(phone_value,'[^0-9]','','g')) not between 10 and 15 then raise exception 'Enter a valid phone number'; end if;
 if p_member_type is null or p_member_type not in ('active','graduate') then raise exception 'Choose Active or Graduate Brother'; end if;
 select coalesce(nullif(email,''),nullif(btrim(p_email),'')) into address from auth.users where id=owner;
 if address is null or address !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Enter a valid contact email'; end if;
 update public.members set full_name=name_value,username=username_value,phone_contact=phone_value,member_type=p_member_type,email_contact=address,registration_complete=true,updated_at=now()
 where user_id=owner and not approved and not rejected and not registration_complete and role='member';
 if not found then raise exception 'Registration already submitted'; end if;
exception when unique_violation then raise exception 'That username is already taken. Choose another.';
end $$;
revoke all on function public.complete_brother_registration(text,text,text,text,text) from public,anon;
grant execute on function public.complete_brother_registration(text,text,text,text,text) to authenticated;

create or replace function public.review_brother_application(p_user_id uuid,p_approve boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.has_admin_permission('requests') then raise exception 'Membership requests permission required'; end if;
 if p_user_id=auth.uid() then raise exception 'Cannot review own application'; end if;
 if p_approve and exists(select 1 from public.members where user_id=p_user_id and not registration_complete) then raise exception 'Brother must complete registration before approval'; end if;
 update public.members set approved=p_approve,rejected=not p_approve,updated_at=now() where user_id=p_user_id and role='member' and approved=false;
 if not found then raise exception 'Application not reviewable'; end if;
end $$;
