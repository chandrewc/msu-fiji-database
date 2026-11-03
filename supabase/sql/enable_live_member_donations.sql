-- Preserve test history; permit real gifts only through the member checkout.
alter table public.stripe_donations drop constraint stripe_donations_livemode_check;
alter table public.stripe_donations add constraint stripe_donations_live_member_only check (not livemode or (member_id is not null and fund = 'alumni'));

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
  if donation.livemode and (donation.member_id is null or donation.fund <> 'alumni') then raise exception 'Live gifts require a member'; end if;
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

