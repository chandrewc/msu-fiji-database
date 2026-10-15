-- FIJI Sigma Mu signup repair: existing accounts are preserved.
-- Run in Supabase SQL Editor as project owner.
begin;
alter table public.members add column if not exists rejected boolean not null default false;
create or replace function public.handle_new_brother()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_name text := btrim(coalesce(new.raw_user_meta_data->>'full_name',''));
  v_username text := lower(btrim(coalesce(new.raw_user_meta_data->>'requested_username','')));
  v_type text := coalesce(new.raw_user_meta_data->>'requested_member_type','');
begin
  -- Admin-created users do not need signup metadata.
  if new.raw_user_meta_data->>'requested_username' is null then return new; end if;
  if length(v_name) not between 2 and 120
    or v_username !~ '^[a-z0-9_]{3,32}$'
    or v_type not in ('active','graduate') then
    raise exception 'Invalid membership application';
  end if;
  insert into public.members (user_id,username,full_name,member_type,role,approved,rejected)
  values (new.id,v_username,v_name,v_type,'member',false,false)
  on conflict (user_id) do nothing;
  return new;
end;
$function$;
drop trigger if exists on_auth_brother_created on auth.users;
create trigger on_auth_brother_created
after insert on auth.users for each row
execute function public.handle_new_brother();

-- Backfill only accounts that submitted valid signup metadata.
-- Accounts already present in members, including the administrator, are untouched.
insert into public.members (user_id,username,full_name,member_type,role,approved,rejected)
select u.id,
       lower(btrim(u.raw_user_meta_data->>'requested_username')),
       btrim(u.raw_user_meta_data->>'full_name'),
       u.raw_user_meta_data->>'requested_member_type',
       'member',false,false
from auth.users u
where not exists(select 1 from public.members m where m.user_id=u.id)
  and length(btrim(coalesce(u.raw_user_meta_data->>'full_name',''))) between 2 and 120
  and lower(btrim(coalesce(u.raw_user_meta_data->>'requested_username',''))) ~ '^[a-z0-9_]{3,32}$'
  and u.raw_user_meta_data->>'requested_member_type' in ('active','graduate')
on conflict do nothing;

-- Replace only the approval-related policies; keep any other existing policies.
drop policy if exists "Applicant can read own status" on public.members;
drop policy if exists "Members can read own account" on public.members;
create policy "Members can read own account"
on public.members for select to authenticated
using (user_id = (select auth.uid()));
drop policy if exists "Admins read pending applications" on public.members;
create policy "Admins read pending applications"
on public.members for select to authenticated
using (public.is_member_admin());
-- Prevent public clients from changing approval or role flags.
revoke insert,update,delete on public.members from anon,authenticated;
grant select on public.members to authenticated;
commit;
-- Verify: SELECT username, role, approved, rejected FROM public.members ORDER BY created_at DESC;
