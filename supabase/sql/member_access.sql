-- Reversible access removal; existing member records and privileges are preserved.
alter table public.members add column deactivated_at timestamptz;
alter table public.members add constraint deactivated_members_cannot_be_approved check (deactivated_at is null or not approved);

create function public.is_deactivated_member() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.members where user_id=(select auth.uid()) and deactivated_at is not null)
$$;
revoke all on function public.is_deactivated_member() from public,anon;
grant execute on function public.is_deactivated_member() to authenticated;

create function public.admin_set_brother_access(p_user_id uuid,p_enabled boolean) returns void
language plpgsql security definer set search_path='' as $$
declare target public.members;
begin
 if auth.uid() is null or not public.has_admin_permission('brothers') then raise exception 'Manage Brothers permission required'; end if;
 if p_enabled is null then raise exception 'Choose whether access is enabled'; end if;
 if p_user_id=auth.uid() then raise exception 'You cannot change your own account access'; end if;
 select * into target from public.members where user_id=p_user_id for update;
 if not found then raise exception 'Brother not found'; end if;
 if target.role='super_admin' then raise exception 'The Super Administrator account is protected'; end if;
 if target.role='admin' and not public.is_super_admin() then raise exception 'Only the Super Administrator can change a Full Administrator account'; end if;
 if not target.approved and target.deactivated_at is null then raise exception 'Only previously approved brothers can be deactivated or reactivated'; end if;
 if not target.registration_complete then raise exception 'Brother must complete registration first'; end if;
 if (p_enabled and target.deactivated_at is null) or (not p_enabled and target.deactivated_at is not null) then return; end if;
 update public.members set approved=p_enabled,rejected=false,
 deactivated_at=case when p_enabled then null else now() end,updated_at=now()
 where user_id=p_user_id;
end $$;
revoke all on function public.admin_set_brother_access(uuid,boolean) from public,anon;
grant execute on function public.admin_set_brother_access(uuid,boolean) to authenticated;

CREATE OR REPLACE FUNCTION public.protect_member_privileged_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$ begin if new.user_id is distinct from old.user_id or new.username is distinct from old.username or new.role is distinct from old.role or new.approved is distinct from old.approved or new.rejected is distinct from old.rejected or new.deactivated_at is distinct from old.deactivated_at or new.created_at is distinct from old.created_at then raise exception 'Protected membership fields cannot be changed'; end if; new.updated_at=now(); return new; end $function$
;
CREATE OR REPLACE FUNCTION public.review_brother_application(p_user_id uuid, p_approve boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null or not public.has_admin_permission('requests') then raise exception 'Membership requests permission required'; end if;
 if p_user_id=auth.uid() then raise exception 'Cannot review own application'; end if;
 if p_approve and exists(select 1 from public.members where user_id=p_user_id and not registration_complete) then raise exception 'Brother must complete registration before approval'; end if;
 update public.members set approved=p_approve,rejected=not p_approve,updated_at=now() where user_id=p_user_id and role='member' and approved=false and deactivated_at is null;
 if not found then raise exception 'Application not reviewable'; end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.complete_brother_registration(p_full_name text, p_username text, p_phone text, p_member_type text, p_email text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare owner uuid:=auth.uid(); address text; username_value text:=lower(btrim(p_username)); name_value text:=btrim(p_full_name); phone_value text:=btrim(p_phone);
begin
 if owner is null then raise exception 'Sign in first'; end if;
 if not exists(select 1 from public.members where user_id=owner and not approved and not rejected and not registration_complete and role='member' and deactivated_at is null) then raise exception 'Registration is not available for this account'; end if;
 if name_value is null or length(name_value) not between 2 and 120 then raise exception 'Enter your full name'; end if;
 if username_value is null or username_value !~ '^[a-z0-9._-]{3,40}$' then raise exception 'Use 3–40 letters, numbers, dots, underscores or hyphens for your username'; end if;
 if phone_value is null or length(phone_value)>30 or phone_value !~ '^[+0-9 ()-]+$' or length(regexp_replace(phone_value,'[^0-9]','','g')) not between 10 and 15 then raise exception 'Enter a valid phone number'; end if;
 if p_member_type is null or p_member_type not in ('active','graduate') then raise exception 'Choose Active or Graduate Brother'; end if;
 select coalesce(nullif(email,''),nullif(btrim(p_email),'')) into address from auth.users where id=owner;
 if address is null or address !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Enter a valid contact email'; end if;
 update public.members set full_name=name_value,username=username_value,phone_contact=phone_value,member_type=p_member_type,email_contact=address,registration_complete=true,updated_at=now()
 where user_id=owner and not approved and not rejected and not registration_complete and role='member' and deactivated_at is null;
 if not found then raise exception 'Registration already submitted'; end if;
exception when unique_violation then raise exception 'That username is already taken. Choose another.';
end $function$
;
CREATE OR REPLACE FUNCTION public.audit_chapter_admin_activity()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare actor uuid:=auth.uid(); actor_label text; verb text; target text; info text;
begin
if actor is null then return coalesce(new,old); end if;
select full_name into actor_label from public.members where user_id=actor;
if tg_table_name='members' then
 if tg_op='UPDATE' then
  if old.deactivated_at is distinct from new.deactivated_at then verb:=case when new.deactivated_at is null then 'Reactivated brother' else 'Deactivated brother' end;
  elsif old.approved is distinct from new.approved or old.rejected is distinct from new.rejected then verb:=case when new.approved then 'Approved membership' when new.rejected then 'Rejected membership' else 'Updated membership status' end;
  elsif old.role is distinct from new.role then verb:='Changed administrator role';
  elsif actor is distinct from new.user_id then verb:='Edited brother profile';
  else return new; end if;
  target:=new.full_name;
 else return coalesce(new,old); end if;
elsif tg_table_name='newsletters' then verb:='Published newsletter';target:=new.title;
elsif tg_table_name='announcements' then verb:='Posted chapter news';target:=new.title;
else return coalesce(new,old); end if;
insert into public.admin_activity_log(actor_id,actor_name,action,target_name,details) values(actor,coalesce(actor_label,'Administrator'),verb,target,info);
return coalesce(new,old);
end $function$
;
create policy "deactivated accounts have no member access" on public.member_admin_permissions as restrictive for all to authenticated using (not (select public.is_deactivated_member())) with check (not (select public.is_deactivated_member()));
create policy "deactivated accounts have no member access" on public.alumni_businesses as restrictive for all to authenticated using (not (select public.is_deactivated_member())) with check (not (select public.is_deactivated_member()));
create policy "deactivated accounts have no member access" on public.alumni_contacts as restrictive for all to authenticated using (not (select public.is_deactivated_member())) with check (not (select public.is_deactivated_member()));
create policy "deactivated accounts have no member access" on public.alumni_crm_status as restrictive for all to authenticated using (not (select public.is_deactivated_member())) with check (not (select public.is_deactivated_member()));
create policy "deactivated accounts have no member access" on public.alumni_donations as restrictive for all to authenticated using (not (select public.is_deactivated_member())) with check (not (select public.is_deactivated_member()));
create policy "deactivated accounts have no member access" on public.announcements as restrictive for all to authenticated using (not (select public.is_deactivated_member())) with check (not (select public.is_deactivated_member()));
create policy "deactivated accounts have no member access" on public.newsletter_email_preferences as restrictive for all to authenticated using (not (select public.is_deactivated_member())) with check (not (select public.is_deactivated_member()));
create policy "deactivated accounts have no member access" on public.newsletters as restrictive for all to authenticated using (not (select public.is_deactivated_member())) with check (not (select public.is_deactivated_member()));
create policy "deactivated accounts have no member access" on public.admin_activity_log as restrictive for all to authenticated using (not (select public.is_deactivated_member())) with check (not (select public.is_deactivated_member()));
create policy "deactivated accounts have no member access" on public.stripe_donations as restrictive for all to authenticated using (not (select public.is_deactivated_member())) with check (not (select public.is_deactivated_member()));
create policy "deactivated accounts have no member access" on public.site_permissions as restrictive for all to authenticated using (not (select public.is_deactivated_member())) with check (not (select public.is_deactivated_member()));
create policy "deactivated accounts have no avatar access" on storage.objects as restrictive for all to authenticated using (bucket_id<>'brother-avatars' or not (select public.is_deactivated_member())) with check (bucket_id<>'brother-avatars' or not (select public.is_deactivated_member()));
