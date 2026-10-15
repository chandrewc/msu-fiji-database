-- FIJI ΣΜ: run ONCE in Supabase SQL Editor after schema-fixed.sql
-- Signups create pending records; only approved admins can approve/reject.
alter table public.members add column if not exists rejected boolean not null default false;
alter table public.members alter column role set default 'member';
alter table public.members alter column approved set default false;
drop policy if exists "Applicant can read own status" on public.members;
create policy "Applicant can read own status" on public.members for select to authenticated
using (user_id = (select auth.uid()));
-- Never grant client UPDATE on members; approvals happen only through checked RPC.
revoke insert, update, delete on public.members from anon, authenticated;
grant select (user_id, username, full_name, member_type, role, approved, rejected,
graduation_year, pledge_class, hometown, city, state, employer, job_title,
industry, linkedin_url, open_to_mentoring, open_to_internships, bio, created_at)
on public.members to authenticated;
create or replace function public.handle_new_brother()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  requested_name text := trim(coalesce(new.raw_user_meta_data->>'full_name',''));
  requested_username text := lower(trim(coalesce(new.raw_user_meta_data->>'requested_username','')));
  requested_type text := coalesce(new.raw_user_meta_data->>'requested_member_type','');
begin
  if length(requested_name) < 2 or length(requested_name) > 120
     or requested_username !~ '^[a-z0-9_]{3,32}$'
     or requested_type not in ('active','graduate') then
    -- Dashboard-created admin users may not have signup metadata.\n    -- They are not given a member record until manually bootstrapped.\n    if new.raw_user_meta_data->>'requested_username' is null then\n      return new;\n    end if;\n    raise exception 'Invalid brother application information';
  end if;
  insert into public.members(user_id,username,full_name,member_type,role,approved,rejected)
  values(new.id,requested_username,requested_name,requested_type,'member',false,false);
  return new;
end;
$$;
drop trigger if exists on_auth_brother_created on auth.users;
create trigger on_auth_brother_created after insert on auth.users
for each row execute function public.handle_new_brother();
revoke all on function public.handle_new_brother() from public, anon, authenticated;
-- Only admins may review and change application status. Not callable by anonymous users.
create or replace function public.review_brother_application(p_user_id uuid, p_approve boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_member_admin() then
    raise exception 'Not authorized';
  end if;
  if p_user_id = (select auth.uid()) then
    raise exception 'Cannot review your own account';
  end if;
  update public.members
  set approved = p_approve, rejected = not p_approve, updated_at = now()
  where user_id = p_user_id and role = 'member' and approved = false and rejected = false;
  if not found then raise exception 'Application not found or already reviewed'; end if;
end;
$$;
revoke all on function public.review_brother_application(uuid,boolean) from public,anon;
grant execute on function public.review_brother_application(uuid,boolean) to authenticated;
-- Admin bootstrap is manual. In Authentication > Users create your own user,
-- then use the UUID in this statement (run separately after account creation):
-- INSERT INTO public.members(user_id,username,full_name,member_type,role,approved)
-- VALUES ('YOUR-AUTH-UUID','chandler','Chandler Chambliss','active','admin',true)
-- ON CONFLICT (user_id) DO UPDATE SET role='admin',approved=true,rejected=false;
-- Only execute bootstrap for the verified owner of this Supabase project.
