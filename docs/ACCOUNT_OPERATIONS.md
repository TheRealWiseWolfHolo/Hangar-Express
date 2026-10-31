# Account operation ownership

Every asynchronous account operation carries a coordinator identity, account ID,
context generation and operation ID. A result commits only while those remain
current. Switching, replacing a session, sign-out or active-account removal
invalidates work before the first suspension. Removing a different saved account
preserves the active account's work. Account-storage transitions have a short
exclusive gate; it is released before slow cache restoration or refresh.

Cancellation reduces wasted work but does not establish ownership. Cancelled
callers can stop waiting through a single-resolution result relay even if a
service ignores cancellation. The abandoned worker remains tracked until it
actually finishes. Its invalid operation ID fences progress, cookies, snapshots,
errors, banners and cleanup. An old defer must never clear a newer refresh.
Account switching and sign-out do not wait for those abandoned workers.

Read operations own their progress, log batches, errors and presentation cleanup.
Cached restores also check an in-memory snapshot revision so an older disk read
cannot replace a newer result for the same account. Account-specific translation
preloads and delayed image work are cancelled/fenced; shared catalog/dictionary
services remain global. Root UI identity changes at a context boundary to reset
old sheets and local presentation state. Authentication completions check their
flow/request identifiers. Checkout-cookie callbacks carry the account ID and
generation captured when the checkout was prepared.

## Mutations and recovery

One mutation gate covers authorization, submission, cookie persistence and
post-action reconciliation. A switch can abandon local work but cannot undo an
RSI request already submitted. Before submission, a preference marker is written
under a SHA256 hash of the account identity (no cookies, passwords or account
labels). Pending markers survive account switches and are loaded by a new app
model. They are local metadata, not server-side idempotency keys or a guarantee
against a crash before preferences reach disk.

A definitive returned response can resolve a known rejection while its owner is
still current. Successful inventory actions keep the gate and marker through
reconciliation and the snapshot-store save call. Normal in-flight actions do not
show the recovery panel. An obsolete, cancelled or failed submitted request with
an uncertain outcome retains its marker. Never automatically replay the action.

Recovery requires a full/hangar read that starts after local submission work has
settled and stays clear of a newer submission, followed by explicit user
acknowledgement that they reviewed the RSI account, including cart/device state
where relevant. A read that overlaps the pending request cannot unlock recovery.
Refresh alone is not proof a server mutation did not happen. The Account page
provides the refresh, review link and acknowledgement; no automated purchase,
gift, melt or repeated mutation is part of recovery.

## Persistence boundary

Snapshot saves reserve an account revision synchronously on the UI owner before
any task is scheduled. A persistence coordinator runs one backend operation at a
time and coalesces pending saves for the same account. Delete/clear barriers
supersede queued older saves and follow an active write, preventing later write
completion from recreating deleted data. A flush waits for work accepted before
its barrier; each receipt reports its own success, supersession or error. Accepted
writes survive caller cancellation. The queue is in process; abrupt OS termination
can still interrupt pending work, so it is not a transactional server outbox.

The file backend is an actor with synchronous filesystem/JSON work on its own
executor. It uses atomic replacement and a versioned envelope, reads legacy JSON,
retains damaged originals before replacing them after a successful refresh, and
refuses to overwrite unknown future schemas. Missing files are distinguished from
unreadable/corrupt data. Storage failures surface in the UI, and reconciliation
clears its recovery marker only after a successful persistence receipt. Explicit
cache/account deletion also removes retained damaged-cache backups.

## Validation

`AccountOperationCoordinatorTests` covers generations, pending markers, account
isolation, reconciliation leases and recovery read barriers. Delayed AppModel
fixtures deliberately ignore cancellation; assertions join real worker completion
rather than merely the cancelled caller. They exercise switch-away-and-back,
sign-out/removal, late progress/errors, pre-cancelled callers, cached restore races,
authorization overlap, submitted uncertain actions, checkout cookies and auth
responses. Positive cases verify valid refresh saves and normal reconciliation
still work. No live RSI mutation is issued by these tests.
