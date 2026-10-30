# Reversible brother access

In Admin → Manage Brothers, select an enabled brother, then **Deactivate brother** and confirm. Use the **Deactivated brothers** account filter to find the same record and **Reactivate brother**. Profile fields, Active/Graduate status, donation history, roles, and delegated permissions are preserved.

The guarded `admin_set_brother_access` RPC requires Manage Brothers permission. It rejects changes to the caller or any Super Administrator; only a Super Administrator can change a Full Administrator's access. Only previously approved accounts can be restored, and incomplete/pending applications continue through their existing review flow.

Deactivation sets `approved=false` and `deactivated_at` atomically. A database constraint prevents an account from being both approved and deactivated. Existing approval-based database and Edge Function checks therefore deny access with previously issued sessions and future Google or password sign-ins. Additional restrictive policies block private owner-only records and new avatar access. Users may read their own membership row to display the deactivated notice. Public chapter information remains public.

The browser checks membership on focus, return to the tab, and every minute while visible, then closes profile/PDF overlays and hides member pages when access is removed. Data already downloaded cannot be recalled. Reactivation restores approval and clears the deactivation timestamp. Both actions are recorded in the administrator activity log. Newsletter sending remains paused.

Validation: rollback SQL tests exercise ordinary/delegated/full/super administrator permissions, self/protected-account restrictions, live RLS under authenticated role with a retained identity, private data denial, preserved profile and permissions, approval-review bypass prevention, reactivation, and both audit events. Seven JavaScript tests exercise UI confirmation, RPC payloads, filters, error recovery, protected controls, and page compilation; seven existing Google registration regression tests also pass. No real member was deactivated during validation.
