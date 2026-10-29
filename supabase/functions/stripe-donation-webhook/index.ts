import Stripe from 'npm:stripe@23.0.0';
import { createClient } from 'npm:@supabase/supabase-js@2.99.1';
import { isTestKey } from '../_shared/donations.ts';

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const key = Deno.env.get('STRIPE_DONATIONS_TEST_KEY');
  const secret = Deno.env.get('STRIPE_DONATIONS_TEST_WEBHOOK_SECRET');
  if (!isTestKey(key) || !secret) return new Response('Not configured', { status: 503 });
  const stripe = new Stripe(key, { apiVersion: '2026-09-30.endive', maxNetworkRetries: 2 });
  let event;
  try {
    event = await stripe.webhooks.constructEventAsync(await req.text(), req.headers.get('stripe-signature') || '', secret, undefined, Stripe.createSubtleCryptoProvider());
  } catch { return new Response('Invalid signature', { status: 400 }); }
  if (event.livemode) return new Response('Test events only', { status: 400 });
  const supported = new Set(['checkout.session.completed', 'checkout.session.async_payment_succeeded', 'checkout.session.async_payment_failed', 'checkout.session.expired', 'charge.refunded']);
  if (!supported.has(event.type)) return new Response('Ignored', { status: 200 });
  try {
    const object = event.data.object;
    const db = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false, autoRefreshToken: false } });
    let sessionId = null, paymentIntent = null, status, refunded = 0;
    if (event.type === 'charge.refunded') {
      paymentIntent = typeof object.payment_intent === 'string' ? object.payment_intent : object.payment_intent?.id;
      if (!paymentIntent) return new Response('Ignored', { status: 200 });
      const sessions = await stripe.checkout.sessions.list({ payment_intent: paymentIntent, limit: 1 });
      const session = sessions.data[0];
      if (!session?.metadata?.donation_id) return new Response('Ignored', { status: 200 });
      sessionId = session.id;
      const found = await db.from('stripe_donations').select('id,member_id,amount_cents,currency,livemode').eq('checkout_session_id', sessionId).maybeSingle();
      if (found.error || !found.data) throw Error('Donation lookup failed');
      if (found.data.id !== session.metadata.donation_id || found.data.member_id !== session.metadata.member_id || found.data.amount_cents !== object.amount || found.data.currency !== object.currency || found.data.livemode !== object.livemode) return new Response('Donation mismatch', { status: 400 });
      refunded = object.amount_refunded;
      status = refunded === object.amount ? 'refunded' : 'partially_refunded';
    } else {
      if (object.metadata?.donation_id == null) return new Response('Ignored', { status: 200 });
      sessionId = object.id;
      paymentIntent = typeof object.payment_intent === 'string' ? object.payment_intent : object.payment_intent?.id;
      if (event.type === 'checkout.session.expired') status = 'expired';
      else if (event.type === 'checkout.session.async_payment_failed') status = 'failed';
      else if (object.payment_status === 'paid') status = 'paid';
      else return new Response('Awaiting payment', { status: 200 });
      const found = await db.from('stripe_donations').select('id,member_id,amount_cents,currency,livemode').eq('checkout_session_id', sessionId).maybeSingle();
      if (found.error) throw found.error;
      if (!found.data) throw Error('Donation not found');
      if (found.data.id !== object.metadata.donation_id || found.data.member_id !== object.metadata.member_id || found.data.amount_cents !== object.amount_total || found.data.currency !== object.currency || found.data.livemode !== object.livemode) return new Response('Donation mismatch', { status: 400 });
    }
    const processed = await db.rpc('record_stripe_donation_event', { p_event_id: event.id, p_session_id: sessionId, p_payment_intent_id: paymentIntent || null, p_status: status, p_refunded_cents: refunded });
    if (processed.error) throw processed.error;
    return new Response('OK', { status: 200 });
  } catch { return new Response('Event processing failed; retry delivery', { status: 500 }); }
});
