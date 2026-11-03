# Brother Network live Stripe donations

Scope: one-time USD donations by approved graduate brothers in `brothers.msufiji.com`. Public Giving remains test-only. No recurring billing, dues collection, tax, saved-card charging, or automatic live charges are added.

## Activation

Supabase Edge Function Secrets must contain:

- `STRIPE_DONATIONS_LIVE_KEY`: a live restricted Stripe key for the chapter's FIJI MS State account. Allow Checkout Sessions write/read, the dependencies required for inline price/product creation, and account read. Refund handling lists Checkout Sessions by PaymentIntent. Do not grant key-management, payout, bank-account, or refund write permissions.
- `STRIPE_DONATIONS_LIVE_WEBHOOK_SECRET`: the signing secret from the chapter live account's webhook endpoint.
- `STRIPE_DONATIONS_LIVE_ACCOUNT_ID`: `acct_1UVhQu0LKcs9BAsZ`.
- `STRIPE_DONATIONS_MODE`: `live` only after the other three settings and the webhook are verified. The default remains `test`; a missing or invalid live configuration disables checkout instead of falling back to test payments.

Never store secret values in GitHub, browser code, chat, or committed environment files. Use Supabase Edge Function Secrets. The original test key and signing secret remain configured independently for public Giving and historical sandbox events.

Live webhook URL: `https://tzrmtdwsspobcbucwtrj.supabase.co/functions/v1/stripe-donation-webhook`.
Events: `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `checkout.session.async_payment_failed`, `checkout.session.expired`, `charge.refunded`. Use API version `2026-09-30.endive` to match the existing SDK.

## Payment safeguards

The checkout verifies membership and deactivation status, amount/currency, account identity and ability to accept charges, environment, and idempotent session metadata. The frontend explicitly sends its displayed environment so a stale test screen cannot open a live checkout after a server mode change. Historical test payments remain separate in the donation history. A pending browser redirect never marks a gift paid.

The shared webhook verifies each environment with its own signing secret, checks session metadata/amount/currency/environment against the stored gift, and handles delayed success/failure, expiry, duplicate events, out-of-order delivery, and refunds. It continues processing test events when the Brother Network is live. Database constraints permit live records only for authenticated member donations designated `alumni`; guest Giving records cannot become live.

Real online gifts remain in `stripe_donations`, separately from manually entered CRM gifts, to avoid accidental duplicate totals. Payer details and receipts are available in Stripe. Confirm Stripe's successful-payment email settings before rollout. No claim of tax deductibility is made.

## Rollback

Set `STRIPE_DONATIONS_MODE=test`. Do not delete live keys or live webhook configuration while real events or refunds may still arrive. The webhook intentionally keeps processing both independently configured environments. Do not drop live history or relabel historical gifts as test transactions.
