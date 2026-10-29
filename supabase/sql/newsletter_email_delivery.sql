-- Only newsletters published after this migration are queued. No historical backfill.
create table public.newsletter_email_preferences (
 user_id uuid primary key references public.members(user_id) on delete cascade,
 enabled boolean not null default true
);
alter table public.newsletter_email_preferences enable row level security;
grant select,insert,update on public.newsletter_email_preferences to authenticated;
grant all on public.newsletter_email_preferences to service_role;
create policy "Own newsletter preferences" on public.newsletter_email_preferences for all to authenticated
 using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));

create table public.newsletter_email_batches (
 id uuid primary key default gen_random_uuid(),
 newsletter_id uuid not null references public.newsletters(id) on delete cascade,
 title text not null, body text not null, issue_date date not null, pdf_url text,
 recipients jsonb not null check(jsonb_typeof(recipients)='array' and jsonb_array_length(recipients) between 1 and 100),
 status text not null default 'pending' check(status in ('pending','sending','sent','failed','review')),
 first_attempt_at timestamptz, claimed_at timestamptz, sent_at timestamptz,
 provider_ids jsonb, last_error text, created_at timestamptz not null default now()
);
create index newsletter_email_batches_issue on public.newsletter_email_batches(newsletter_id);
alter table public.newsletter_email_batches enable row level security;
revoke all on public.newsletter_email_batches from anon,authenticated;
grant all on public.newsletter_email_batches to service_role;

create function public.queue_newsletter_email() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.newsletter_email_batches(newsletter_id,title,body,issue_date,pdf_url,recipients)
 select new.id,new.title,coalesce(new.body,''),new.issue_date,new.pdf_url,jsonb_agg(jsonb_build_object('email',email) order by email)
 from (
  select email,(row_number() over(order by email)-1)/100 as batch from (
   select distinct lower(trim(coalesce(nullif(trim(m.email_contact),''),u.email))) as email
   from public.members m join auth.users u on u.id=m.user_id
   left join public.newsletter_email_preferences p on p.user_id=m.user_id
   where m.approved and not m.rejected and m.member_type in ('active','graduate') and coalesce(p.enabled,true)
  ) addresses where email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
 ) numbered group by batch;
 return new;
end $$;
revoke all on function public.queue_newsletter_email() from public,anon,authenticated;
create trigger queue_newsletter_email after insert on public.newsletters for each row execute function public.queue_newsletter_email();

create function public.claim_newsletter_email_batch(p_newsletter_id uuid) returns setof public.newsletter_email_batches
language plpgsql security invoker set search_path='' as $$
begin
 -- Resend retains idempotency keys for 24h. Stop uncertain retries before that window ends.
 update public.newsletter_email_batches set status='review',last_error='Sending was not confirmed within 23 hours. Review Resend before resending.'
 where newsletter_id=p_newsletter_id and status in ('sending','failed') and first_attempt_at<now()-interval '23 hours';
 return query update public.newsletter_email_batches b set status='sending',claimed_at=now(),first_attempt_at=coalesce(first_attempt_at,now()),last_error=null
 where b.id=(select j.id from public.newsletter_email_batches j where j.newsletter_id=p_newsletter_id
 and (j.status in ('pending','failed') or (j.status='sending' and j.claimed_at<now()-interval '2 minutes'))
 order by j.created_at,j.id for update skip locked limit 1) returning b.*;
end $$;
revoke all on function public.claim_newsletter_email_batch(uuid) from public,anon,authenticated;
grant execute on function public.claim_newsletter_email_batch(uuid) to service_role;

create function public.newsletter_email_status() returns table(newsletter_id uuid,queued bigint,sent bigint,pending bigint,failed bigint,review bigint)
language sql security definer set search_path='' as $$
 select b.newsletter_id,sum(jsonb_array_length(b.recipients))::bigint,
 coalesce(sum(jsonb_array_length(b.recipients)) filter(where status='sent'),0)::bigint,
 coalesce(sum(jsonb_array_length(b.recipients)) filter(where status in ('pending','sending')),0)::bigint,
 coalesce(sum(jsonb_array_length(b.recipients)) filter(where status='failed'),0)::bigint,
 coalesce(sum(jsonb_array_length(b.recipients)) filter(where status='review'),0)::bigint
 from public.newsletter_email_batches b where auth.uid() is not null and public.has_admin_permission('newsletter') group by b.newsletter_id;
$$;
revoke all on function public.newsletter_email_status() from public,anon;
grant execute on function public.newsletter_email_status() to authenticated;
