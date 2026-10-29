alter table public.newsletter_email_batches add column transport text not null default 'transactional' check(transport in ('transactional','marketing'));
alter table public.newsletter_email_batches alter column transport set default 'marketing';
alter table public.newsletter_email_batches add column segment_id text;
alter table public.newsletter_email_batches add column broadcast_id text;
alter table public.newsletter_email_batches add column sync_cursor integer not null default 0;
-- Never silently resend historical transactional campaigns through marketing.
update public.newsletter_email_batches set status='review',last_error='Legacy transactional campaign: review before any manual resend.' where transport='transactional' and status<>'sent';
