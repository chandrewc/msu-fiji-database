# Newsletter email pause

Automatic newsletter email is temporarily paused. The website inserts new newsletter rows directly using the existing authenticated newsletter permissions. The queue_newsletter_email trigger is disabled, and the publish-newsletter Edge Function returns paused/503 after authenticating newsletter administrators, before any provider call. Retry and connection controls and email preferences are hidden. Account SMTP remains independent.

No provider credential, contact, or campaign was deleted. Previously submitted broadcasts cannot be recalled. To resume deliberately, restore the marketing handler, re-enable the queue trigger, and restore the marketing UI. Do not backfill newsletters posted during the pause.

newsletter-template.html exports the previous marketing template with manually replaceable NEWSLETTER_TITLE, ISSUE_DATE, NEWSLETTER_BODY and NEWSLETTER_PDF_URL placeholders. The RESEND_UNSUBSCRIBE_URL merge tag is supplied by Resend Broadcasts. Remove the PDF paragraph when no PDF is provided. Newsletter body HTML must be escaped unless authoring trusted HTML directly.
