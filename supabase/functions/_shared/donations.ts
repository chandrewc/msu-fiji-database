export const NETWORK_ORIGIN = 'https://brothers.msufiji.com';
export const ORIGINS = new Set([NETWORK_ORIGIN, 'https://chandrewc.github.io']);

export function parseDonation(input) {
  const amount = String(input?.amount ?? '').trim();
  if (!/^(?:0|[1-9]\d{0,5})(?:\.\d{1,2})?$/.test(amount)) throw Error('Enter a dollar amount with at most two decimal places.');
  const [whole, fraction = ''] = amount.split('.');
  const cents = Number(whole) * 100 + Number(fraction.padEnd(2, '0'));
  if (!Number.isSafeInteger(cents) || cents < 100 || cents > 10000000) throw Error('Choose an amount between $1 and $100,000.');
  if (typeof input.purpose !== 'string' || input.purpose.length > 500) throw Error('The donation purpose must be 500 characters or fewer.');
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(input.request_id || '')) throw Error('Start a new donation and try again.');
  return { cents, purpose: input.purpose.trim(), requestId: input.request_id };
}

export function checkoutParameters(donation, memberId) {
  return {
    mode: 'payment',
    submit_type: 'donate',
    integration_identifier: 'sigma_mu_alumni_donations_qxpkmsva',
    client_reference_id: donation.id,
    line_items: [{ price_data: { currency: 'usd', unit_amount: donation.amount_cents, product_data: { name: 'Sigma Mu Alumni Donation' } }, quantity: 1 }],
    automatic_tax: { enabled: false },
    allow_promotion_codes: false,
    metadata: { donation_id: donation.id, member_id: memberId },
    payment_intent_data: { metadata: { donation_id: donation.id, member_id: memberId } },
    success_url: NETWORK_ORIGIN + '/?donation=' + donation.id + '#donate',
    cancel_url: NETWORK_ORIGIN + '/?donation_cancelled=1#donate',
  };
}

export function isTestKey(key) {
  return /^(sk|rk)_test_/.test(key || '');
}


export function donationConfig(env, mode = env('STRIPE_DONATIONS_MODE') || 'test') {
  const livemode = mode === 'live';
  const key = env(livemode ? 'STRIPE_DONATIONS_LIVE_KEY' : 'STRIPE_DONATIONS_TEST_KEY');
  const secret = env(livemode ? 'STRIPE_DONATIONS_LIVE_WEBHOOK_SECRET' : 'STRIPE_DONATIONS_TEST_WEBHOOK_SECRET');
  const accountId = env('STRIPE_DONATIONS_LIVE_ACCOUNT_ID');
  const validKey = livemode ? /^(sk|rk)_live_/.test(key || '') : isTestKey(key);
  const ready = ['test', 'live'].includes(mode) && validKey && !!secret && (!livemode || accountId === 'acct_1UVhQu0LKcs9BAsZ');
  return { mode, livemode, key, secret, accountId, ready };
}
export async function liveAccountReady(stripe, config) {
  if (!config.ready) return false;
  if (!config.livemode) return true;
  const account = await stripe.accounts.retrieve();
  return account.id === config.accountId && account.charges_enabled === true;
}
