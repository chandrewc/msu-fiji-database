# Sigma Mu website and Brother Network handoff

Updated: October 28, 2026. Prepared for a collaborator using Claude, Claude Code, Codex, or another development tool.

This describes the deployed architecture and the owner's established requirements. Inspect the current repository and database before changing them: this is a snapshot, not a complete database schema or authorization to make unrelated production changes.

## 1. Projects and entry points

| Component | Repository | Live site |
| --- | --- | --- |
| Public chapter website | [chandrewc/msu-fiji-public](https://github.com/chandrewc/msu-fiji-public) | [Public site](https://chandrewc.github.io/msu-fiji-public/) |
| Brother Network / brotherhood database | [chandrewc/msu-fiji-database](https://github.com/chandrewc/msu-fiji-database) | [Brother Network](https://chandrewc.github.io/msu-fiji-database/) |

Both sites use Supabase project **`tzrmtdwsspobcbucwtrj`**, API URL **`https://tzrmtdwsspobcbucwtrj.supabase.co`**. The sites are plain HTML/CSS/JavaScript hosted through GitHub Pages. They use Supabase JavaScript through a CDN; neither currently has an application build step or package-based test runner.

Relevant public-site entry points:

- `about.html`: chapter history, founding brothers, and awards.
- `leadership.html`: Cabinet and Executive Board & Committees.
- `recruitment.html`: recruitment chair and IFC information.
- `manager.html`: sign-in-required Website Manager for structured chapter information.
- `builder.html`: page/layout editor with draft and publish actions.
- `admin.html`: separate website administration interface for additional content sections and media.

The Brother Network's `index.html` is the main application with inline CSS and JavaScript. `classic.html` is an older alternate file; do not treat it as the current application without checking routing.

## 2. Access for a new collaborator

These are separate permissions; access to one does not confer the others:

1. GitHub collaborator access to **both** repositories, using the collaborator's own account.
2. Supabase organization/project access, using the collaborator's own account. Scope their MCP connection to the project above and the capabilities needed.
3. An approved Brother Network account if they need to use the application.
4. Website permissions in `site_permissions` if they need to use Website Manager or the page editor.

Never share account passwords, Supabase service-role/secret keys, personal access tokens, or signed private-image URLs in this document or public repositories. A frontend publishable key already exists in source; it is not an administrator credential. Database grants, RLS, and server-side checks provide authorization.

Suggested working practice: make changes on a branch, submit a pull request, and review before deployment. Coordinate production SQL changes with the owner and other collaborators.

## 3. Public-site file map

Paths below are relative to `msu-fiji-public`.

| File | Purpose |
| --- | --- |
| `script.js` | Shared header/footer, original page templates in `contents`, public additional `site_content`, awards data and rendering |
| `styles.css` | Main site styling, Cabinet and committee layout, awards table |
| `chapter-data.js` | Reads structured chapter data and renders leadership, recruitment, images, philanthropy, contact information, and spotlight content |
| `site-pages.js` | Reads published page records, updates navigation, applies published blocks or original-layout edits, then imports `chapter-data.js` |
| `original-editor.js` | Shared text/image selection and positional original-layout edits |
| `site-renderer.js` | Renders page-builder blocks |
| `manager.html`, `manager.js`, `manager.css` | Structured chapter manager, authentication and role checks, officer/member editing, media upload |
| `builder.html`, `builder.js`, `builder.css` | Original-layout and block editor, drafts, publishing, version history |
| `admin.html`, `admin.js` | Additional website sections, publishing, and media library |
| `sql/` | SQL changes recorded during maintenance; not a complete fresh-install schema |
| `tests/committee-members.cjs` | Playwright behavior checks using fixtures, not live writes |
| `tests/site-publication-security.sql` | Transactional publication/access regression checks |
| `tests/public-leadership-access.sql` | Transactional public leadership/access regression checks |

## 4. Brother Network features and database map

Paths below are relative to `msu-fiji-database`.

- `index.html`: account registration/sign-in, approval state, directory/profile editing, private profile images, newsletters, announcements, alumni businesses, and administrator screens.
- Administrator features include invitations, application review, brother management, delegated permissions, website permissions, activity log, and alumni outreach/donation records.
- Alumni tracking supports relationship status, priority, contact history, follow-up dates, donation history/totals, search/filtering, and CSV export. It records gifts; it does not process payments.
- `supabase/approval-setup.sql`, `supabase/signup-repair.sql`, and `supabase/install-missing-functions.sql` are historical setup/repair scripts. Inspect the live schema and migration history before running them; do not assume they represent every subsequent change.

Shared public-schema objects, grouped by responsibility:

| Area | Tables / view |
| --- | --- |
| Membership | `members`, `member_admin_permissions` |
| Private chapter community | `announcements`, `newsletters`, `alumni_businesses` |
| Private alumni CRM | `alumni_contacts`, `alumni_donations`, `alumni_crm_status` |
| Audit | `admin_activity_log` |
| Website roles and extra sections | `site_permissions`, `site_content`, `site_media` |
| Website drafts/history | `site_pages`, `site_page_versions`, `site_original_versions` |
| Public page publishing | `site_page_publications` table, `site_published_pages` view |
| Public structured chapter data | `chapter_officers`, `chapter_settings` |

Important RPC/function names used by the applications:

- `review_brother_application(p_user_id uuid, p_approve boolean)`
- `admin_update_brother(p_user_id uuid, p_changes jsonb)`
- `admin_set_brother_role(p_user_id uuid, p_make_admin boolean)`
- `set_member_permissions(p_user_id uuid, p_permissions text[])`
- `member_contact(p_user_id uuid)`
- `site_role()` — website authorization lookup; anonymous callers do not have execute access.

The active Edge Function `admin-invite-brother` is called from the Brother Network invitation form. Its deployed source is not included in the current repository tree. Retrieve its current source from Supabase before changing or redeploying it; do not rebuild it from assumptions or print its environment secrets.

## 5. Authentication and permissions

Membership approval is represented in `members` (`approved`, `rejected`), and the application role is in `members.role`. The interface recognizes full administrators through `admin` and `super_admin`.

Delegated administrator capabilities are stored separately in `member_admin_permissions`. Current UI permission keys are:

`invite`, `requests`, `brothers`, `newsletter`, `news`, `businesses`, `sitepermissions`, `activity`, `alumni`.

Website roles are independently stored in `site_permissions`:

- `super_admin` and `editor`: structured manager editing and page publishing.
- `contributor`: permitted draft work; cannot publish. Structured manager editing requires Editor or Super Admin.

`site_role()` also checks that the associated member is approved and not rejected. Hiding controls in HTML is not a security boundary; retain grants, RLS, and function-level authorization checks.

**Owner's visibility requirement:** the chapter website, all leadership positions, committee names, and public website images are readable without sign-in. Website management requires authentication. This requirement does **not** make Brother Network records, private profile photos, alumni CRM, or unpublished page drafts public.

Do not restore a dashboard back button to Website Manager: the owner explicitly asked to remove it.

## 6. Leadership requirements

`chapter_officers` stores both `cabinet` and `executive` categories. Important fields include `id`, `position`, `name`, `email`, `photo_url`, `display_order`, `committee_members`, and the legacy `is_visible` field.

- Cabinet must be the most prominent leadership section. The President is featured above the remaining Cabinet officers.
- Cabinet supports photos and email; missing Cabinet photos currently use initials.
- Commissioner stays first within the executive section, below Cabinet.
- Executive positions and committee heads have names and optional email addresses, without photos.
- A position may have multiple chairs. Names share the existing name field. Emails share the existing text field and are rendered as separate email links.
- The email input accepts commas, semicolons, whitespace, or the word `and` between addresses; the manager normalizes them for saving.
- Committee members are **names only**. `committee_members` is a non-null `text[]` on the parent position. Adding/editing/removing rows is published when the parent officer is saved.
- `Committee only — no chair` clears chair name/email and preserves member names. Do not require a head for groups such as Chaplins, T-Shirt, or New Member Mentors.
- Committee-only cards must not reserve blank space for a missing chair. The `.committee-only-card` style overrides the normal header minimum height.
- All positions are public regardless of the old `is_visible` flag. The public query intentionally does not filter by it.
- The current layout uses aligned committee card rows, with a separate wide roster for committees with at least 12 members. It replaced uneven masonry columns that the owner disliked.
- Keep Cabinet photo support and committee-only behavior when modifying layouts. Existing unused executive photo URLs are not displayed.

## 7. Publishing: two different paths

### Structured Website Manager changes

`manager.js` writes directly to `chapter_officers` and `chapter_settings`. A successful Save publishes those values immediately to the public readers in `chapter-data.js`. This does not use the page-builder draft/publish workflow.

Current settings keys used by the manager/renderers include `recruitment`, `recruitment_ifc`, `site_images`, `brother_of_month`, `philanthropy_events`, `philanthropy_impact`, and `contact`. There is also an older `ifc_recruitment` key in the database; verify the code's key before editing it.

`site_images` entries use `page:photo-key`, matching `data-photo-key` targets. Uploading a file into the photo library alone does not attach it to an officer or page: save its URL into the intended field and save that item.

### Page-builder publication

1. `site_pages` holds private `draft_blocks` / `layout_draft` and published `published_blocks` / `layout_published`.
2. Save Draft retains work privately. Publish sets the appropriate published representation.
3. `private.sync_site_page_publication()` maintains the published-only `site_page_publications` projection through an AFTER INSERT/UPDATE/DELETE trigger.
4. Public code reads `site_published_pages`, a **security-invoker, SELECT-only view** over that projection.
5. An unpublished row has both published representations null and is absent from the projection. Original static chapter pages still render from `script.js` when no override is published.
6. Renaming, unpublishing, or deleting a source page updates/removes its projection automatically.

Never make `site_pages` generally public just to fix a rendering error: that risks exposing draft columns on already-published rows. Never allow browser writes to the published view/projection; editors write to the protected source table.

### Rendering-order caution

The current sequence is static templates, published blocks/original edits, then structured chapter rendering. Original-layout edits use positional text/image indexes; DOM changes can shift those targets. Leadership sections are regenerated from `chapter_officers`, so direct original-layout edits to those generated cards can be overwritten. Use Website Manager for leadership names, emails, photos, and committees, and test any editor changes against the final public render.

## 8. Images and storage

| Bucket | Intended visibility | Current usage |
| --- | --- | --- |
| `sigma-mu-site` | Public | Public website images, WebP uploads, references in `site_media` and chapter fields |
| `brother-avatars` | Private | Member profile photos; the Brother Network requests temporary signed URLs |

Do not make `brother-avatars` public. Do not replace public website image URLs with private signed URLs that expire.

A recent broken recruitment image was caused by URLs pointing to deleted storage objects, not by bucket privacy. The recruitment setting and static fallback were repaired to use an existing uploaded Ethan photo. Check actual HTTP responses and image `naturalWidth`, not only whether a URL looks valid. The media library still contains historical references that may point to deleted objects; do not treat each media row as proof the file exists. Do not delete or bulk-replace assets without checking where they are used.

## 9. Awards and chapter history

The About page now has **one** chronological Historical Awards & Achievements section. It merges 33 owner-supplied awards with the existing Zerman Trophy summary and 2024 Highest IFC GPA honor (35 rows total at this handoff).

- Data: `chapterAwards` in `script.js`.
- Rendering: `awardsSection()` in `script.js`.
- Styling: `.chapter-awards` / `.awards-table` in `styles.css`.
- Anchor: `about.html#awards`.
- The owner requested the 2001 entry without the word “unconfirmed.” Preserve supplied wording unless asked to edit it; this list is not an independently verified historical source.
- Do not recreate a separate recognition-card section above the archive.

## 10. Security changes already applied

Recorded in the public repository's `sql/` directory:

1. `executive_committee_members.sql`: names-only arrays on executive positions.
2. `secure_site_published_pages.sql`: published-only projection, invoker view, restricted writes, removal of client TRUNCATE access on `site_pages`, contributor publication protection including `layout_published`.
3. `restrict_internal_trigger_rpc_access.sql`: trigger functions are not directly callable client RPCs; permissions-management RPC requires a signed-in caller and retains administrator checks.
4. `restore_public_officer_reads.sql`: separates anonymous reads from the private role helper.
5. `make_all_leadership_positions_public.sql`: all positions publicly readable, per the owner.
6. `restrict_public_chapter_writes.sql`: anonymous officer/settings writes and unsafe client privileges removed while public SELECT remains.

These are **already applied**, not a script bundle to rerun. Some are intentionally not idempotent. Inspect Supabase migration history, schema, grants, policies, triggers, and dependencies before planning further changes.

Known prior regression: a SELECT policy on `chapter_officers` called `site_role()` for anonymous users. Because they cannot execute that helper, the public Leadership request returned HTTP 401 with PostgreSQL code `42501`, and the page showed its old placeholder. Keep anonymous read policies independent of administrator-only functions. Do not solve that by disabling RLS.

The Security Definer View error was cleared. Other advisories may remain for privileged authorization helpers and disabled leaked-password protection. Recheck the current advisors and inspect function checks before changing permissions; do not assume every security-definer helper can be removed without breaking legitimate authorization. No claim of a complete security audit is made here.

## 11. Development, verification, and deployment

There is no full automated application suite or checked-in Node dependency manifest at present. Use current tools available in your environment; prior machine-specific runtime paths are not portable.

For source changes:

1. Pull the current head in the correct repository. Check for local changes and concurrent updates.
2. Serve the repository over local HTTP to exercise browser modules. For example: `python3 -m http.server 8000`.
3. Run JavaScript syntax checks such as `node --check script.js`, `node --check manager.js`, and `node --check chapter-data.js` for changed files. For Brother Network, extract/check the inline module and inspect browser errors.
4. Run `tests/committee-members.cjs` from the public repository root using Node with Playwright available. It verifies create/edit/remove, committee-only saves and spacing, multiple email handling, Cabinet fields, public grouping, and responsive layout using fixtures.
5. For permissions/publication changes, review and run the SQL tests as an administrator in the intended environment. They use transactions and rollback test changes. `site-publication-security.sql` temporarily changes a website-role row inside its transaction and requires an approved website super admin; do not strip its rollback.
6. Visually inspect desktop, tablet, and phone widths using realistic names and committee sizes. Check overflow, alignment, missing images, and duplicate sections.
7. Test the deployed public site in a clean **signed-out** browser, not only the administrator's session. Then test authorized editing separately. Confirm private member data and drafts remain inaccessible to unauthorized accounts.
8. Commit frontend files and SQL records; apply reviewed schema changes through Supabase migrations. A GitHub commit does not apply SQL automatically.
9. GitHub Pages deployment follows the repository's configured publishing source (the public site's documented setup is `main`, root). Verify the actual Pages deployment and live assets after pushing. GitHub Pages can lag the commit.
10. Bump affected HTML asset query versions and nested module import versions when changing shared files. Updating `chapter-data.js` without updating the cached `site-pages.js` import chain may leave visitors using older code.

Do not mark a change complete based solely on a SQL query as `postgres`: test the actual `anon` and `authenticated` access paths. A UI that works for an admin can still fail publicly.

## 12. Getting started in Claude

After connecting both repositories and project-scoped Supabase access, use this as the starting brief:

> Read `docs/PROJECT_HANDOFF.md` and inspect the current source in both `chandrewc/msu-fiji-public` and `chandrewc/msu-fiji-database`. Both use Supabase project `tzrmtdwsspobcbucwtrj`. Keep public website data public, private membership/CRM data private, Cabinet visually prominent, Commissioner first within executive leadership, and committee-only/multiple-email support intact. Inspect live schema and permissions before proposing database changes. Make the requested changes on a branch and verify public and authorized behavior before submitting them for review.

This document contains project structure and operational context, not member records or credentials. Copies live in both repositories; update both when shared architecture changes.
