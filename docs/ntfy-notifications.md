# Outbound ntfy notifications

Firstmate can push a small number of notifications to a phone through [ntfy](https://ntfy.sh), so a captain away from the machine learns that something wants them.
It is off until a home opts in.

This page covers setup, what a notification does and does not reveal, and how the channel behaves when it breaks.
[`configuration.md`](configuration.md#outbound-ntfy-notifications-env) is the single owner of the configuration schema, and `bin/fm-ntfy-lib.sh`'s header owns the exact delivery mechanics.

## What it is, and what it is not

The notifier is a **secondary, non-authoritative pager**.
Firstmate decides, records, and acts exactly as it did before; the notification is a copy of an outcome firstmate already published, sent to a second screen.

- Nothing arrives back from ntfy.
  There is no command channel, no reply path, and no button that performs a firstmate action.
- Reading, clearing, swiping, or deleting a notification changes nothing in firstmate.
  A decision stays open until it is answered in firstmate, and a merge still needs the captain's word there.
- An accepted publish means the ntfy server stored the message.
  It does not mean a device received it, a screen displayed it, or a person read it.
- ntfy being slow, throttled, or completely down never blocks project work, delays supervision, or consumes the firstmate notification the captain would have seen anyway.

## What gets notified

Five events, all of them things firstmate would already bring to the captain:

| Event | ntfy priority | What the notification says |
| --- | --- | --- |
| A decision is waiting | 4 | "A decision is waiting for you in firstmate." |
| Work stopped and needs the captain | 4 | "Work stopped and needs you in firstmate." |
| A sign-in is required | 4 | "A sign-in is required before work can continue." |
| A change is ready for review | 3 | "A change is ready for your review." |
| A change was delivered | 2 | "A change was delivered." |

Routine progress is never notified.
A worker's own words, its logs, a report body, a project or client name, a branch, a finding, or a file path are never published: only the event kind crosses over.

Adding a sixth kind means editing the one catalog in `bin/fm-ntfy-lib.sh`, which is what keeps this list reviewable.

## Setup

1. **Pick where the topic lives.**
   On the hosted ntfy service, use a reserved or otherwise protected topic and a dedicated account.
   Without access control a topic name is effectively its own password, so anyone who learns it can read, and publish to, everything on it.
   Self-hosting moves that trust to your own server, at the cost of running it (TLS, updates, backups, availability, and mobile push); it does not by itself add end-to-end encryption.
2. **Create a publish token** for that account and write it, alone, to a private file:

   ```sh
   umask 077
   printf '%s\n' '<TOKEN>' > ~/.config/firstmate/ntfy-token
   chmod 600 ~/.config/firstmate/ntfy-token
   ```

   An ntfy access token carries nearly the whole account's authority and cannot be narrowed to a single topic, so give it an account that does nothing else.
3. **Point the home at it** in its own gitignored `.env` (placeholders only; substitute your own values):

   ```sh
   FM_NTFY_URL=https://<NTFY_HOST>
   FM_NTFY_TOPIC=<OPAQUE_PROTECTED_TOPIC>
   FM_NTFY_TOKEN_FILE=/<ABSOLUTE>/<PRIVATE>/ntfy-token
   ```

   Leave `FM_NTFY_SCOPE` and `FM_NTFY_PR_LINKS` unset to start; both default to the quietest, least revealing setting.
4. **Prove the transport** without inventing a fleet event:

   ```sh
   bin/fm-ntfy.sh test
   ```

   This publishes one clearly-labelled self-test message and reports whether ntfy accepted it.
   Acceptance is the only thing it can prove; look at the phone to learn whether the message actually arrived.
   The self-test leaves no record behind and can never be mistaken for real work.
5. **Turn on unattended delivery** in the live home:

   ```sh
   bin/fm-ntfy.sh arm
   ```

   `bin/fm-ntfy.sh status` then reports the notifier's state without ever printing the topic or the token.

Each home configures itself.
A secondmate home notifies only when it has its own `.env`, its own topic, and its own token file; nothing is inherited.

## Privacy

Treat a phone lock screen as public, and treat the ntfy server as able to see what it stores.

- **No end-to-end encryption.**
  ntfy documents TLS between client and server, not end-to-end encryption of message content in the standard publish path.
  The server caches messages, may forward them to Firebase, and handles the topic name.
  Assume the server operator, and depending on the client the push providers, can see at least metadata and possibly content.
- **Lock screen.**
  The default `minimal` scope exists for exactly this: every notification is one fixed generic sentence with a constant "Firstmate" title.
  `FM_NTFY_SCOPE=detail` adds the firstmate task id, which usually names the work; turn it on only if a preview showing that id is acceptable wherever the phone is.
- **Links.**
  `FM_NTFY_PR_LINKS=on` attaches a pull-request or merge-request URL, which reveals the repository and number in the notification.
  With it off, no link is published and none is stored.
  A link is only ever a `view` action or the tap target; firstmate never publishes an ntfy `http` action button, because such a button would let anyone holding the device, or replaying an old notification, trigger an action with no identity, correlation, expiry, or replay protection.
- **Mobile push.**
  Android through Google Play and iOS both go through Firebase, and iOS then through APNs, so content and metadata can traverse those providers.
  Android from F-Droid against a self-hosted server can avoid Firebase with a persistent connection.
  A self-hosted server usually still needs an upstream for instant iOS delivery.
  Web Push involves the browser vendor's push service.
  Validate the client you actually use; one working does not validate the others.
- **Retention.**
  Messages are cached server-side for a limited window (12 hours by default) so a phone that was offline can catch up; after that window a missed message is gone from the cache.
  A self-hosted server's default cache is in memory and does not survive a restart unless it is configured with SQLite or PostgreSQL.
- **Rotation.**
  The token is re-read from its file on every publish, so replacing the file's contents rotates the credential with no restart.
  If a topic or token is exposed, rotate the token and move to a new protected topic, and treat everything published during the retention window as exposed.

## Delivery and failure

Publication is **at-least-once, deduplicated by firstmate**.
An intent is written to disk before any network call, an identity-bound receipt is written after the server accepts it, and that receipt suppresses every later publication of the same event, including after a restart.
A crash in the window between a successful publish and its receipt causes a repeat rather than a loss; the retry reuses the same ntfy sequence id so a client can collapse it visually.
That sequence id is display de-duplication only and is not server-side idempotency, which is why firstmate's own receipt is the authority.

| Condition | What happens |
| --- | --- |
| Phone offline | The server's cache replays it on reconnect, within the retention window; past it, the message is gone from the cache and firstmate still holds the outcome. |
| Server unreachable, TLS or DNS failure, timeout | The notification is kept and retried with bounded exponential backoff and jitter. Work is unaffected. |
| HTTP 401 or 403 | Treated as a revoked token or wrong access rules: the notification is kept, retries back off hard rather than hammering, and the credential is reported once. |
| HTTP 429 | `Retry-After` is honoured when the server sends one, otherwise the ordinary bounded backoff applies. Never a retry loop. |
| HTTP 5xx | Bounded backoff, then delivered once the server recovers. |
| Retries exhausted | The notification is parked, never discarded. It is reported once and stays visible in `bin/fm-ntfy.sh status`. |
| Configuration half-finished | Reported as one actionable line rather than failing silently, so a channel the captain believes is working cannot be quietly dead. |
| ntfy completely unavailable | Firstmate keeps working and keeps its own notifications. One degradation is reported; nothing is consumed or replaced. |

Away mode changes nothing here.
The same five events are published with the same content, and being away grants no additional authority to anything.

The channel is independent of which primary harness and runtime backend the home uses.
It opens no pane, launches no agent, and issues no backend command: the events it projects come from status-log classification and forge outcomes, and delivery runs as an ordinary registered watcher check.

## Related

- `config/wedge-alarm`'s `command:` channel is a separate, narrower seam that fires only when an away-mode escalation cannot be delivered inside the firstmate session; see [`wedge-alarm.md`](wedge-alarm.md).
  It is not part of this notifier and has its own configuration.
- [`configuration.md`](configuration.md#outbound-ntfy-notifications-env) owns the configuration schema.
- `tests/fm-ntfy.test.sh` pins this page's guarantees: the inert default, configuration refusals, secret containment, the event allowlist, link allowlisting, the view-only action, the durability and duplicate windows, every response class above, per-home isolation, and that publishing mutates no firstmate record.
