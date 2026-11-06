# Account operations

## Ownership and cancellation

Every asynchronous account operation has an account, context generation, and
operation ID. Results can update the app only while that owner is current.
Switching accounts, replacing a session, signing out, or removing the active
account invalidates old work before waiting for services. Removing another saved
account does not interrupt the active account.

Cancellation stops waiting where possible; it does not prove that a service
stopped. Workers that ignore cancellation remain tracked until they finish.
Their old results cannot change cookies, snapshots, progress, errors, or cleanup
for a newer operation. Account switching does not wait for them.

Cached restores also check the current snapshot revision. Translation preloads,
image work, authentication completions, and checkout cookie callbacks carry
matching context checks. Shared public catalogs remain separate from account data.

## Mutations and recovery

One mutation gate covers local authentication, RSI submission, cookie saving, and
reconciliation. Password-confirmed actions are unavailable for read-only accounts.
Browser navigation and checkout messages also follow the [security policy](SECURITY.md).

Before submission, the app records a pending marker under a hash of the account
identity. It contains no password, cookie, or account label. The marker survives
account switches, but is not a server idempotency key or a crash-proof disk write.

A known rejection can clear the marker while its operation is current. A successful
inventory action keeps it until reconciliation and snapshot saving finish. An
uncertain submitted result keeps the marker. The app never automatically replays
that action: switching accounts cannot undo an RSI request already sent.

Recovery needs a fresh Hangar/Full Refresh after submission work has settled, then
explicit confirmation that the user reviewed the RSI account. A read that overlaps
the request cannot unlock recovery. Refresh alone does not prove what happened to
a purchase, gift, melt, cart change, or device action.

## Snapshot storage

The persistence coordinator reserves revisions before scheduling work. It runs
one backend operation at a time and combines pending saves for the same account.
Delete and clear operations prevent older writes from restoring removed data.
Each save reports success, replacement by a newer save, or failure.

The file backend uses atomic writes and a versioned format. It reads legacy data,
preserves damaged files for recovery, and refuses to overwrite unknown future
schemas. Storage errors are visible in the app. Explicit cache/account deletion
also removes retained damaged-cache copies.

Accepted writes survive caller cancellation, but abrupt app termination can still
interrupt queued work. This local queue is not a durable server outbox.

## Feedback and validation

Account or authentication changes dismiss the feedback form. It does not submit
mail or upload attachments in the background. See [feedback](FEEDBACK.md).

Tests cover late workers, account switches, authentication, checkout callbacks,
recovery barriers, save order, deletion, migration, and storage failures. They wait
for actual worker completion and never submit live RSI mutations. See [testing](TESTING.md).
