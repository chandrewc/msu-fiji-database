-- Both named public funds may receive live gifts; client access remains unchanged.
alter table public.stripe_donations drop constraint stripe_donations_live_member_only;
alter table public.stripe_donations add column client_fingerprint text check (client_fingerprint is null or client_fingerprint ~ '^[0-9a-f]{64}$');
create index stripe_donations_guest_fingerprint_created on public.stripe_donations(client_fingerprint,created_at desc) where member_id is null;

-- Reserve atomically so concurrent requests cannot bypass creation limits.
create function public.reserve_public_donation(p_id uuid,p_fund text,p_amount_cents bigint,p_purpose text,p_livemode boolean,p_fingerprint text)
returns setof public.stripe_donations language plpgsql security invoker set search_path='' as $$
declare existing public.stripe_donations;
begin
 if p_fund is null or p_fund not in ('persistence','parents') or p_amount_cents is null or p_amount_cents not between 100 and 10000000 or p_purpose is null or length(p_purpose)>500 or p_livemode is null or p_fingerprint is null or p_fingerprint !~ '^[0-9a-f]{64}$' then raise exception 'invalid_donation'; end if;
 perform pg_catalog.pg_advisory_xact_lock(759124681907::bigint);
 select * into existing from public.stripe_donations where id=p_id for update;
 if found then
  if existing.member_id is not null or existing.fund<>p_fund or existing.amount_cents<>p_amount_cents or existing.purpose<>p_purpose or existing.livemode<>p_livemode or existing.status<>'pending' then raise exception 'donation_conflict'; end if;
  return next existing; return;
 end if;
 if (select count(*) from public.stripe_donations where member_id is null and created_at>now()-interval '1 minute')>=30 or (select count(*) from public.stripe_donations where member_id is null and client_fingerprint=p_fingerprint and created_at>now()-interval '15 minutes')>=5 then raise exception 'donation_rate_limit'; end if;
 return query insert into public.stripe_donations(id,member_id,fund,amount_cents,currency,purpose,livemode,client_fingerprint)
 values(p_id,null,p_fund,p_amount_cents,'usd',p_purpose,p_livemode,p_fingerprint) returning *;
end $$;
revoke all on function public.reserve_public_donation(uuid,text,bigint,text,boolean,text) from public,anon,authenticated;
grant execute on function public.reserve_public_donation(uuid,text,bigint,text,boolean,text) to service_role;

CREATE OR REPLACE FUNCTION public.record_stripe_donation_event(p_event_id text, p_session_id text, p_payment_intent_id text, p_status text, p_refunded_cents bigint DEFAULT 0)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare donation public.stripe_donations; inserted integer; refund_total bigint;
begin
  if p_status not in ('paid','failed','expired','partially_refunded','refunded') then raise exception 'Invalid payment state'; end if;
  select * into donation from public.stripe_donations
  where (p_session_id is not null and checkout_session_id=p_session_id)
     or (p_payment_intent_id is not null and payment_intent_id=p_payment_intent_id)
  for update;
  if not found then return 'ignored'; end if;
  if donation.payment_intent_id is not null and p_payment_intent_id is not null and donation.payment_intent_id<>p_payment_intent_id then raise exception 'Payment mismatch'; end if;
  if p_refunded_cents<0 or p_refunded_cents>donation.amount_cents then raise exception 'Invalid refund amount'; end if;
  insert into public.stripe_donation_events(event_id,donation_id) values(p_event_id,donation.id) on conflict do nothing;
  get diagnostics inserted=row_count;
  if inserted=0 then return 'duplicate'; end if;
  refund_total=greatest(donation.refunded_cents,p_refunded_cents);
  update public.stripe_donations set
    payment_intent_id=coalesce(donation.payment_intent_id,p_payment_intent_id),
    refunded_cents=refund_total,
    status=case when refund_total=donation.amount_cents then 'refunded'
      when refund_total>0 then 'partially_refunded'
      when donation.status='paid' or p_status='paid' then 'paid'
      when donation.status in ('failed','expired') then donation.status
      else p_status end,
    paid_at=case when p_status='paid' or refund_total>0 then coalesce(donation.paid_at,now()) else donation.paid_at end
  where id=donation.id;
  return 'processed';
end $function$

;
