-- One-time alumni donations. Test payments remain separate from the real CRM ledger.
create table public.stripe_donations (
  id uuid primary key,
  member_id uuid not null references public.members(user_id),
  amount_cents bigint not null check (amount_cents between 100 and 10000000),
  currency text not null default 'usd' check (currency = 'usd'),
  purpose text not null default '' check (length(purpose) <= 500),
  checkout_session_id text unique,
  payment_intent_id text unique,
  status text not null default 'pending' check (status in ('pending','paid','failed','expired','partially_refunded','refunded')),
  refunded_cents bigint not null default 0 check (refunded_cents between 0 and amount_cents),
  livemode boolean not null default false check (livemode = false),
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
create index stripe_donations_member_created on public.stripe_donations(member_id,created_at desc);
alter table public.stripe_donations enable row level security;
revoke all on public.stripe_donations from public,anon,authenticated;
grant select on public.stripe_donations to authenticated;
grant all on public.stripe_donations to service_role;
create policy "Members read their Stripe donations" on public.stripe_donations for select to authenticated using (member_id=(select auth.uid()));
create policy "Alumni administrators read Stripe donations" on public.stripe_donations for select to authenticated using ((select public.has_admin_permission('alumni')));

create table public.stripe_donation_events (
  event_id text primary key,
  donation_id uuid not null references public.stripe_donations(id),
  processed_at timestamptz not null default now()
);
alter table public.stripe_donation_events enable row level security;
revoke all on public.stripe_donation_events from public,anon,authenticated;
grant all on public.stripe_donation_events to service_role;

create function public.record_stripe_donation_event(p_event_id text,p_session_id text,p_payment_intent_id text,p_status text,p_refunded_cents bigint default 0)
returns text language plpgsql security invoker set search_path='' as $$
declare donation public.stripe_donations; inserted integer; refund_total bigint;
begin
  if p_status not in ('paid','failed','expired','partially_refunded','refunded') then raise exception 'Invalid payment state'; end if;
  select * into donation from public.stripe_donations
  where (p_session_id is not null and checkout_session_id=p_session_id)
     or (p_payment_intent_id is not null and payment_intent_id=p_payment_intent_id)
  for update;
  if not found then return 'ignored'; end if;
  if donation.livemode then raise exception 'Test donations only'; end if;
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
end $$;
revoke all on function public.record_stripe_donation_event(text,text,text,text,bigint) from public,anon,authenticated;
grant execute on function public.record_stripe_donation_event(text,text,text,text,bigint) to service_role;
