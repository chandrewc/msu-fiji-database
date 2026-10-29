# Sigma Mu alumni donations

Scope: one-time USD alumni donations in the Brother Network's existing Support Us page. No dues, subscriptions, invoicing, added tax, or live charges. No statement that donations are tax deductible.

Stripe implementation planner accepted hosted web Checkout, guide `iguide_61Vf61kgAGaBMouKE411pZro4JJCV`, for the connected FIJI MS State sandbox (`acct_1UVd2r1pZro4JJCV`). The documentation fallback was also installed after the planner was initially unavailable.

## Flow

1. An approved graduate brother chooses an amount and optional purpose in the existing page.
2. An authenticated Supabase function checks membership and validates USD cents, bounds, purpose length, request ID, and allowed browser origin. A stable request ID and Stripe idempotency key prevent duplicate checkouts on retry.
3. The function creates Stripe-hosted Checkout with `automatic_tax.enabled=false`, no tax rates, no invoices, no recurring price, and no added surcharge. Card details never enter this application. Dynamic payment methods remain enabled.
4. Stripe returns the donor to the existing donation page. The page reads the donor's own server-recorded status; it does not mark a gift paid from a URL parameter.
5. A signature-verified webhook checks the stored session, metadata, amount, currency, and test mode, then records payment/failure/expiry/refund events atomically. Duplicate event IDs and out-of-order events do not duplicate gifts or downgrade paid/refunded records.

## Storage and permissions

`stripe_donations` is distinct from manually recorded real alumni giving. Every row is marked test-only, and these transactions do not inflate the existing CRM totals. Members can SELECT their own payments. Approved alumni administrators can SELECT donation records. Browser roles cannot insert, update, delete, or call the event-processing RPC. Only server functions use service-role credentials.

Server secrets: `STRIPE_DONATIONS_TEST_KEY` and `STRIPE_DONATIONS_TEST_WEBHOOK_SECRET`. Use Supabase Edge Function Secrets, preferably a restricted test API key with only the required Checkout/PaymentIntent/Charge/Product/Price permissions. No secret values belong in source, committed environment files, or browser markup. The user-provided secret exposed in chat should be rotated before use.

## Required webhook

Endpoint: `https://tzrmtdwsspobcbucwtrj.supabase.co/functions/v1/stripe-donation-webhook`.

Events: `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `checkout.session.async_payment_failed`, `checkout.session.expired`, `charge.refunded`.

Checkout function retains gateway JWT verification and also validates the user's token. The webhook alone disables gateway JWT verification because Stripe authenticates with its signed raw request body; it rejects invalid signatures and live-mode events.

## Before accepting real donations

This implementation intentionally refuses live keys and live records. A separate reviewed launch must confirm the chapter Stripe account and bank destination, account activation and permitted fundraising use, live key/webhook setup, HTTPS, real receipts, and payment/refund reconciliation. No automatic switch from test to live is supported.

## Verification

Test server amount validation, eligibility, no-tax checkout payloads, retry/idempotency, signature rejection, completed-but-unpaid sessions, duplicates, delayed success/failure, refunds arriving before completion, and private read/write boundaries. Complete a Stripe sandbox checkout and confirm webhook-driven status before calling the integration operational.
