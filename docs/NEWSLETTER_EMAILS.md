# Automatic newsletter emails

Publishing in Admin → Manage Newsletters calls the authenticated `publish-newsletter` Edge Function. It checks `has_admin_permission('newsletter')` and publishes with a stable UUID, then sends private per-recipient emails through Resend's batch API. Sender: Sigma Mu Chapter <notifications@msufiji.com>. Body includes the issue text, optional HTTPS PDF link, archive link, and email preferences link.

Only newly inserted issues are queued. No old newsletters are backfilled. Approved, non-rejected Active and Graduate brothers are included, except members who disable newsletter email in the Newsletters page. Contact email is used when available; otherwise the account email is used. Duplicate email addresses receive one message. Preferences apply to future issues.

A database trigger snapshots immutable batches of at most 100 recipients. Recipient addresses and provider IDs are server-only. Admin status is aggregate counts only. `sent` means accepted by Resend, not proof of inbox delivery; inspect Resend for bounces/delivery. Existing auth SMTP is independent.

Required server-only secret: `RESEND_NEWSLETTER_API_KEY`, scoped to sending for msufiji.com. Never store it in source or browser code. Without it the function refuses publication rather than reporting that emails were sent.

After a partial/provider failure, the newsletter remains published and the admin can choose Retry pending emails. Successful batches are never retried. Each batch uses a stable Resend idempotency key. Concurrent claims are locked; abandoned claims can resume after two minutes. Uncertain failures older than 23 hours require manual review in Resend before any resend, because provider idempotency expires after 24 hours. Requests process at most 20 batches/75 seconds; any remainder can be resumed using the same retry action. There is no scheduled retry worker.

Deleting a newsletter also deletes unsent batches; it cannot recall emails already sent or cancel an in-flight request. PDFs are linked, not attached.

Validation: Node tests cover input/HTML safety, authorization, configuration failure, private recipients, idempotency keys, and provider failures. Database rollback tests cover audience selection, queue creation, claim exclusion, stale retry protection, and server-only table access. No real brother receives test messages.
