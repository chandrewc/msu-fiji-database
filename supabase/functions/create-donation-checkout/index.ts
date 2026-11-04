import Stripe from 'npm:stripe@23.0.0';
import { createClient } from 'npm:@supabase/supabase-js@2.99.1';
import { NETWORK_ORIGIN, ORIGINS, parseDonation, checkoutParameters, donationConfig, liveAccountReady } from '../_shared/donations.ts';

Deno.serve(async (req) => {
  const origin = req.headers.get('origin') || '';
  const headers = { 'Access-Control-Allow-Origin': ORIGINS.has(origin) ? origin : NETWORK_ORIGIN, 'Access-Control-Allow-Headers': 'authorization, apikey, x-client-info, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Vary': 'Origin', 'Cache-Control': 'no-store', 'Content-Type': 'application/json' };
  const reply = (body, status = 200) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (req.method !== 'POST') return reply({ error: 'Method not allowed.' }, 405);
  if (origin && !ORIGINS.has(origin)) return reply({ error: 'Origin not allowed.' }, 403);
  try {
    const auth = req.headers.get('authorization') || '';
    let input;
    try { input = await req.json(); } catch { return reply({ error: 'Invalid donation request.' }, 400); }
    // Project operators can validate configuration without impersonating a graduate
    // or exposing secrets. This branch cannot create a Checkout Session or payment.
    if (input?.action === 'configuration') {
      const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
      let secretKeys = [];
      try { secretKeys = Object.values(JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}')).filter(value => typeof value === 'string' && value.startsWith('sb_secret_')); } catch { /* Missing new-style keys fail closed. */ }
      const operator = (serviceKey && auth === 'Bearer ' + serviceKey) || secretKeys.includes(req.headers.get('apikey'));
      if (!operator) return reply({ error: 'Project operator access required.' }, 403);
      const config = donationConfig(name => Deno.env.get(name), 'live');
      const result = { mode: Deno.env.get('STRIPE_DONATIONS_MODE') || 'test', key_configured: /^(sk|rk)_live_/.test(config.key || ''), webhook_configured: !!config.secret, account_configured: config.accountId === 'acct_1UVhQu0LKcs9BAsZ', account_access: false, account_matches: false, charges_enabled: false, payouts_enabled: false, signed_webhook_verified: false, checkout_verified: false };
      if (!result.key_configured) return reply(result);
      const client = new Stripe(config.key, { apiVersion: '2026-09-30.endive', maxNetworkRetries: 2 });
      try {
        const account = await client.accounts.retrieve();
        result.account_access = true; result.account_matches = account.id === 'acct_1UVhQu0LKcs9BAsZ';
        result.charges_enabled = account.charges_enabled === true; result.payouts_enabled = account.payouts_enabled === true;
      } catch { return reply(result); }
      if (config.ready && result.account_matches && input.verify_webhook === true) {
        const payload = JSON.stringify({ id: 'evt_configuration_' + crypto.randomUUID(), type: 'checkout.session.completed', livemode: true, data: { object: { livemode: true, metadata: {} } } });
        const timestamp = Math.floor(Date.now() / 1000);
        const encoder = new TextEncoder();
        const signingKey = await crypto.subtle.importKey('raw', encoder.encode(config.secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
        const digest = await crypto.subtle.sign('HMAC', signingKey, encoder.encode(timestamp + '.' + payload));
        const signature = Array.from(new Uint8Array(digest)).map(byte => byte.toString(16).padStart(2, '0')).join('');
        const response = await fetch(Deno.env.get('SUPABASE_URL') + '/functions/v1/stripe-donation-webhook', { method: 'POST', headers: { 'Content-Type': 'application/json', 'Stripe-Signature': 't=' + timestamp + ',v1=' + signature }, body: payload });
        result.signed_webhook_verified = response.status === 200 && await response.text() === 'Ignored';
      }
      if (config.ready && result.account_matches && result.charges_enabled && input.verify_checkout === true) {
        try {
          const session = await client.checkout.sessions.create({ mode: 'payment', submit_type: 'donate', integration_identifier: 'sigma_mu_configuration_zqvmkpta', line_items: [{ price_data: { currency: 'usd', unit_amount: 100, product_data: { name: 'Configuration verification - do not pay' } }, quantity: 1 }], metadata: { configuration_check: 'true' }, success_url: NETWORK_ORIGIN + '/#donate', cancel_url: NETWORK_ORIGIN + '/#donate' });
          // No URL is returned or visited, and no donor or ledger record is created.
          const expired = await client.checkout.sessions.expire(session.id);
          result.checkout_verified = session.livemode === true && session.amount_total === 100 && session.currency === 'usd' && expired.status === 'expired';
        } catch { result.checkout_verified = false; }
      }
      if (config.ready && result.account_matches && result.charges_enabled && input.verify_public_checkout === true) {
        result.public_checkout_verified = { persistence: false, parents: false };
        for (const fund of ['persistence', 'parents']) {
          try {
            const response = await fetch(Deno.env.get('SUPABASE_URL') + '/functions/v1/create-public-donation-checkout', { method: 'POST', headers: { 'Content-Type': 'application/json', apikey: 'sb_publishable_57LLRCD8y-LWGQ4yVTL7bg__HF20OFF' }, body: JSON.stringify({ fund, amount: '1', purpose: 'Public checkout configuration verification (no payment)', request_id: crypto.randomUUID(), expected_mode: 'live' }) });
            const checkout = await response.json();
            if (!response.ok || checkout.mode !== 'live') continue;
            const url = new URL(checkout.url);
            const sessionId = url.pathname.match(/cs_live_[A-Za-z0-9]+/)?.[0];
            if (url.origin !== 'https://checkout.stripe.com' || !sessionId) continue;
            const session = await client.checkout.sessions.retrieve(sessionId);
            const expired = await client.checkout.sessions.expire(sessionId);
            result.public_checkout_verified[fund] = session.livemode === true && session.amount_total === 100 && session.currency === 'usd' && session.metadata?.fund === fund && session.metadata?.member_id === 'public' && expired.status === 'expired';
          } catch { /* Report only verification booleans, never keys or checkout URLs. */ }
        }
      }
      return reply(result);
    }
    if (!auth.startsWith('Bearer ')) return reply({ error: 'Sign in to continue.' }, 401);
    const db = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: { user }, error: authError } = await db.auth.getUser(auth.slice(7));
    if (authError || !user) return reply({ error: 'Your session expired. Sign in again.' }, 401);
    const { data: member, error: memberError } = await db.from('members').select('approved,rejected,member_type,deactivated_at').eq('user_id', user.id).single();
    if (memberError || !member?.approved || member.rejected || member.member_type !== 'graduate' || member.deactivated_at) return reply({ error: 'Online alumni donations are available to approved graduate brothers.' }, 403);
    const config = donationConfig(name => Deno.env.get(name));
    const stripe = config.ready ? new Stripe(config.key, { apiVersion: '2026-09-30.endive', maxNetworkRetries: 2 }) : null;
    let ready = false;
    try { ready = !!stripe && await liveAccountReady(stripe, config); } catch { ready = false; }
    if (input?.action === 'status') return reply({ ready, mode: config.mode });
    if ((input?.expected_mode && input.expected_mode !== config.mode) || (config.livemode && input?.expected_mode !== 'live')) return reply({ error: 'Payment mode changed. Refresh the page before continuing.' }, 409);
    if (!ready) return reply({ error: 'Online donations are being configured. Please try again later.' }, 503);
    let parsed;
    try { parsed = parseDonation(input); } catch (error) { return reply({ error: error.message }, 400); }
    const pending = { id: parsed.requestId, member_id: user.id, amount_cents: parsed.cents, currency: 'usd', purpose: parsed.purpose, livemode: config.livemode };
    const inserted = await db.from('stripe_donations').insert(pending);
    if (inserted.error && inserted.error.code !== '23505') return reply({ error: 'Could not start your donation. Please try again.' }, 500);
    const { data: donation, error: readError } = await db.from('stripe_donations').select('*').eq('id', pending.id).eq('member_id', user.id).single();
    if (readError || !donation || donation.amount_cents !== pending.amount_cents || donation.purpose !== pending.purpose || donation.livemode !== config.livemode || donation.fund !== 'alumni' || donation.status !== 'pending') return reply({ error: 'Start a new donation before continuing.' }, 409);
    let session;
    if (donation.checkout_session_id) {
      session = await stripe.checkout.sessions.retrieve(donation.checkout_session_id);
      if (session.status !== 'open') return reply({ error: 'This checkout has ended. Start a new donation.' }, 409);
    } else {
      session = await stripe.checkout.sessions.create(checkoutParameters(donation, user.id), { idempotencyKey: 'donation-' + donation.id });
    }
    if (session.livemode !== config.livemode || session.client_reference_id !== donation.id || session.amount_total !== donation.amount_cents || session.currency !== donation.currency) return reply({ error: 'Checkout verification failed. Please start a new donation.' }, 409);
    if (!session.url?.startsWith('https://checkout.stripe.com/')) return reply({ error: 'Checkout is temporarily unavailable.' }, 502);
    if (!donation.checkout_session_id) {
      const saved = await db.from('stripe_donations').update({ checkout_session_id: session.id }).eq('id', donation.id).eq('member_id', user.id);
      if (saved.error) return reply({ error: 'Could not save the checkout. Try again.' }, 500);
    }
    return reply({ url: session.url, donation_id: donation.id, mode: config.mode });
  } catch {
    return reply({ error: 'Unable to open secure checkout. Please try again later.' }, 502);
  }
});


