# Brother Network: live donation frontend

The member donation page is prepared for one-time USD alumni donations through Stripe-hosted Checkout. Only approved, non-deactivated Graduate brothers can start checkout. The page requires the existing status response to report both `mode: "live"` and `ready: true`. Test mode, unavailable credentials, unknown modes, and status failures keep the button disabled. Production readiness is decided by the backend, not a browser setting.

This change does not deploy or modify backend APIs, database structures, Stripe account settings, secrets, webhook endpoints, public Giving, dues payments, subscriptions, or tax configuration. The existing backend supports the live-mode contract; its completion and credentials are a separate step.

## Existing API contract

Use the authenticated Supabase function `create-donation-checkout`:

- Status request: `{ "action": "status" }`. Enable only for `{ "mode": "live", "ready": true }`.
- Checkout request: `{ "amount": "25", "purpose": "optional chapter support", "request_id": "a stable UUID for this attempt", "expected_mode": "live" }`.
- Checkout response: `{ "mode": "live", "url": "https://checkout.stripe.com/...", "donation_id": "..." }`.

The frontend validates amount bounds ($1–$100,000 and at most two decimal places), prevents concurrent duplicate submissions, reuses the request UUID on retries, and accepts only HTTPS Checkout URLs from checkout.stripe.com. Membership, exact amount validation, idempotency, environment, and account ownership must also remain enforced by the backend.

History and return-page checks read only the signed-in member's rows with `livemode=true`. Browser redirects cannot mark gifts paid. An authenticated live donation record must be updated by the verified Stripe webhook before the page confirms payment. Sandbox records remain saved, but are not mixed into live giving history.

## Remaining backend activation

When credentials are available, the backend maintainer should securely configure the existing Supabase secrets:

- `STRIPE_DONATIONS_LIVE_KEY`: a live restricted key with only the permissions needed by the existing checkout implementation. Never put it in HTML, GitHub, chat, or a committed environment file.
- `STRIPE_DONATIONS_LIVE_WEBHOOK_SECRET`: the signing secret for the live webhook endpoint.
- `STRIPE_DONATIONS_LIVE_ACCOUNT_ID`: the chapter live account already expected by the existing backend.
- `STRIPE_DONATIONS_MODE=live`: set only after the live key, account readiness, and live webhook have been verified.

The existing webhook URL is `https://tzrmtdwsspobcbucwtrj.supabase.co/functions/v1/stripe-donation-webhook`. Required configured events are listed in LIVE_STRIPE.md, including payment completion, delayed success/failure, expiry, and refunds. Keep signature verification, event idempotency, amount/currency/environment matching, and test/live event separation. Do not enable automatic tax for this donation flow. Confirm successful-payment receipt settings in Stripe before launch.

Stripe-hosted Checkout receives card information on Stripe's own page. This frontend uses the server-returned Checkout URL; it does not need a publishable Stripe key or Stripe.js. A live restricted key and webhook signing secret belong only in server secrets.

## Validation

Eleven frontend tests cover live readiness, sandbox refusal, unavailable backend, membership restrictions, preset/custom amount validation, expected environment, Checkout URL validation, separated history, authoritative live payment confirmation, and duplicate-submission prevention. No live payment is created or charged during these tests.
