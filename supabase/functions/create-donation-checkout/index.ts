import Stripe from 'npm:stripe@23.0.0';
import { createClient } from 'npm:@supabase/supabase-js@2.99.1';
import { NETWORK_ORIGIN, ORIGINS, parseDonation, checkoutParameters, isTestKey } from '../_shared/donations.ts';

Deno.serve(async (req) => {
  const origin = req.headers.get('origin') || '';
  const headers = { 'Access-Control-Allow-Origin': ORIGINS.has(origin) ? origin : NETWORK_ORIGIN, 'Access-Control-Allow-Headers': 'authorization, apikey, x-client-info, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Vary': 'Origin', 'Cache-Control': 'no-store', 'Content-Type': 'application/json' };
  const reply = (body, status = 200) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (req.method !== 'POST') return reply({ error: 'Method not allowed.' }, 405);
  if (origin && !ORIGINS.has(origin)) return reply({ error: 'Origin not allowed.' }, 403);
  try {
    const auth = req.headers.get('authorization') || '';
    if (!auth.startsWith('Bearer ')) return reply({ error: 'Sign in to continue.' }, 401);
    const db = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: { user }, error: authError } = await db.auth.getUser(auth.slice(7));
    if (authError || !user) return reply({ error: 'Your session expired. Sign in again.' }, 401);
    const { data: member, error: memberError } = await db.from('members').select('approved,rejected,member_type').eq('user_id', user.id).single();
    if (memberError || !member?.approved || member.rejected || member.member_type !== 'graduate') return reply({ error: 'Online alumni donations are available to approved graduate brothers.' }, 403);
    const key = Deno.env.get('STRIPE_DONATIONS_TEST_KEY');
    const ready = isTestKey(key) && !!Deno.env.get('STRIPE_DONATIONS_TEST_WEBHOOK_SECRET');
    let input;
    try { input = await req.json(); } catch { return reply({ error: 'Invalid donation request.' }, 400); }
    if (input?.action === 'status') return reply({ ready, mode: 'test' });
    if (!ready) return reply({ error: 'Online donations are being configured. Please try again later.' }, 503);
    let parsed;
    try { parsed = parseDonation(input); } catch (error) { return reply({ error: error.message }, 400); }
    const pending = { id: parsed.requestId, member_id: user.id, amount_cents: parsed.cents, currency: 'usd', purpose: parsed.purpose, livemode: false };
    const inserted = await db.from('stripe_donations').insert(pending);
    if (inserted.error && inserted.error.code !== '23505') return reply({ error: 'Could not start your donation. Please try again.' }, 500);
    const { data: donation, error: readError } = await db.from('stripe_donations').select('*').eq('id', pending.id).eq('member_id', user.id).single();
    if (readError || !donation || donation.amount_cents !== pending.amount_cents || donation.purpose !== pending.purpose || donation.status !== 'pending') return reply({ error: 'Start a new donation before continuing.' }, 409);
    const stripe = new Stripe(key, { apiVersion: '2026-09-30.endive', maxNetworkRetries: 2 });
    let session;
    if (donation.checkout_session_id) {
      session = await stripe.checkout.sessions.retrieve(donation.checkout_session_id);
      if (session.status !== 'open') return reply({ error: 'This checkout has ended. Start a new donation.' }, 409);
    } else {
      session = await stripe.checkout.sessions.create(checkoutParameters(donation, user.id), { idempotencyKey: 'donation-' + donation.id });
      if (session.livemode) return reply({ error: 'This integration accepts test payments only.' }, 503);
      const saved = await db.from('stripe_donations').update({ checkout_session_id: session.id }).eq('id', donation.id).eq('member_id', user.id);
      if (saved.error) return reply({ error: 'Could not save the checkout. Try again.' }, 500);
    }
    if (!session.url?.startsWith('https://checkout.stripe.com/')) return reply({ error: 'Checkout is temporarily unavailable.' }, 502);
    return reply({ url: session.url, donation_id: donation.id, mode: 'test' });
  } catch {
    return reply({ error: 'Unable to open secure checkout. Please try again later.' }, 502);
  }
});
