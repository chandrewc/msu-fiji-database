-- FIJI Sigma Mu: install missing signup and approval functions.
-- Run once in Supabase SQL Editor as project owner.
-- Existing users and membership records are preserved.
begin;

create or replace function public.handle_new_brother()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_name text := btrim(coalesce(new.raw_user_meta_data->>'full_name', ''));
  v_username text := lower(btrim(coalesce(new.raw_user_meta_data->>'requested_username', '')));
  v_type text := coalesce(new.raw_user_meta_data->>'requested_member_type', '');
begin
  -- Accounts created by an administrator may have no signup metadata.
  if new.raw_user_meta_data->>'requested_username' is null then
    return new;
  end if;

  if length(v_name) not between 2 and 120
     or v_username !~ '^[a-z0-9_]{3,32}$'
     or v_type not in ('active', 'graduate') then
    raise exception 'Invalid brother application information';
  end if;

  insert into public.members
    (user_id, username, full_name, member_type, role, approved, rejected)
  values
    (new.id, v_username, v_name, v_type, 'member', false, false);

  return new;
end;
$$;

drop trigger if exists on_auth_brother_created on auth.users;
create trigger on_auth_brother_created
after insert on auth.users
for each row execute function public.handle_new_brother();

revoke all on function public.handle_new_brother() from public, anon, authenticated;

create or replace function public.review_brother_application(
  p_user_id uuid,
  p_approve boolean
)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_member_admin() then
    raise exception 'Not authorized';
  end if;

  if p_user_id = (select auth.uid()) then
    raise exception 'Cannot review your own account';
  end if;

  update public.members
  set approved = p_approve,
      rejected = not p_approve,
      updated_at = now()
  where user_id = p_user_id
    and role = 'member'
    and approved = false
    and rejected = false;

  if not found then
    raise exception 'Application not found or already reviewed';
  end if;
end;
$$;

revoke all on function public.review_brother_application(uuid, boolean)
from public, anon, authenticated;
grant execute on function public.review_brother_application(uuid, boolean)
to authenticated;

-- Prevent users from editing their own role or approval status directly.
revoke insert, update, delete on public.members from anon, authenticated;

commit;

-- Verification (run separately if desired):
-- select proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
-- where n.nspname='public' and proname in ('handle_new_brother','review_brother_application');
-- select tgname from pg_trigger where tgrelid='auth.users'::regclass and not tgisinternal;
