# Room-code peer grouping for the LocalSend signaling server

## Problem

The signaling server in this repo groups peers by the IP the WebSocket connected from
(`util/ip.rs::get_ip_group`). For IPv4 it groups by the exact public IP (so peers behind
the same NAT collide and discover each other). For IPv6 it groups by `/64` (so devices on
the same local subnet share a prefix and discover each other).

On a dual-stack LAN where one browser dials the signaling server over IPv6 and another
over IPv4, the two peers have unrelated group keys (the NAT public IPv4 vs a `/64` v6
prefix) and never see each other. There is no information available to the server alone
that would let it correlate the two stacks.

## Goal

Allow peers to opt in to a shared **room code** that becomes the peer-visibility key,
overriding IP-based grouping. Two browsers that join the same room see each other
regardless of IP family. Existing IP-based grouping remains the default for peers that
don't pass a room.

## Non-goals

- Authenticated/encrypted rooms. Anyone with the code joins; codes are treated like a
  meeting URL.
- Room expiry / TTL beyond the lifecycle that already applies to IP groups (group is
  cleaned up when the last peer disconnects).
- A protocol version bump. The change is additive and opaque to clients that don't use it.
- Cross-server federation, QR codes, or any UI to "generate" a room.
- Per-room rate limiting. Rate limits stay per-IP so rooms can't bypass DDoS protection.

## Wire-protocol change

The WebSocket register URL gains one optional query parameter, `room`:

```
unchanged:  wss://signal/v1/ws?d=<base64-PeerRegisterDto>
new:        wss://signal/v1/ws?d=<base64-PeerRegisterDto>&room=<code>
```

`room` validation:

- Charset: `[A-Za-z0-9_-]`
- Length: 4 to 64 characters inclusive
- Trimming is **not** applied — leading/trailing whitespace is rejected as invalid

Invalid `room` → HTTP 400 from the upgrade endpoint. Missing `room` → IP grouping
(no change from today).

The `room` value never leaves the server. It is not echoed in any `WsServerMessage`.

## Server design

### Two grouping keys, not one

`ws_controller::handle_socket` currently uses a single `ip_group: String` for both
peer visibility (`tx_map`) and DDoS accounting (`request_count_map`). These split:

| Key                | Purpose                                    | Source                                            |
|--------------------|--------------------------------------------|---------------------------------------------------|
| `peer_group`       | Bucket in `tx_map` for who sees whom       | `room:<code>` if `room` present, else `get_ip_group(ip)` |
| `rate_limit_key`   | Bucket in `request_count_map` for DDoS     | Always `get_ip_group(ip)`                         |

The `room:` prefix on the peer-group key prevents collisions: a user can't pick a room
named `1.2.3.4` and land in someone's NAT bucket.

### Code changes (Rust)

1. `controller/ws_controller.rs::WsQuery` grows `pub room: Option<String>`.
2. New module `util/room.rs` with `pub fn validate_room_code(s: &str) -> Result<&str, ()>`:
   - Returns `Ok(s)` if the input matches the charset and length rules.
   - Returns `Err(())` otherwise. The handler maps to `AppError::status(StatusCode::BAD_REQUEST, None)`.
   - Unit tests cover happy path, too short, too long, bad chars, whitespace, empty.
3. `ws_handler` computes the two keys, then passes both into a refactored
   `handle_socket`.
4. `handle_socket`'s `ip_group` parameter is renamed to `peer_group`, and a separate
   `rate_limit_key: String` parameter is added. All `tx_map.entry(...)` / `tx_map.get(...)`
   / `tx_map.remove(...)` uses switch to `peer_group`. All `protect_ddos_request_count`
   calls switch to `rate_limit_key`. The existing `Connect:` / `Disconnect:` tracing
   log lines are kept; their group-key field shows `peer_group` (so room-grouped
   sessions appear as `room:<code>` in logs — see Security notes about whether that
   is OK).
5. `util/mod.rs` exports `pub mod room;`.

### Tests (Rust)

- `util/room.rs` — unit tests for validation, listed above.
- No integration test changes are required for the existing IP-grouping path (regressions
  would surface in the per-IP `MAX_CONNECTIONS` and `MAX_REQUESTS` behavior, which is
  already covered indirectly by manual testing). If integration test infrastructure
  is added later, the room/IP split is a natural place to add coverage.

## Client design (web)

### State

`store.ts` gains:

```ts
room: null as string | null,
```

`connectionLoop` passes `store.room` into every `SignalingConnection.connect(...)` call.
Because the loop already retries on close, switching rooms is "set `store.room`, then
close the current socket" — the next iteration picks up the new value.

`setupConnection`'s signature does not need a new parameter; the loop reads from
`store` directly, the same way it already reads `store._proposingClient`.

### URL plumbing

`signaling.ts::SignalingConnection.connect` gains `room?: string | null`. When non-empty,
it is appended:

```ts
const qs = `d=${encodedInfo}` + (room ? `&room=${encodeURIComponent(room)}` : "");
const ws = new WebSocket(`${url}?${qs}`);
```

### UI (mirrors PIN)

In `pages/index.vue` header strip, add a third column matching the existing alias / PIN
columns:

```
You              | PIN          | Room
{alias}          | {pin|none}   | {room|none}
```

Click handler `updateRoom`:

```ts
const updateRoom = async () => {
  const input = prompt(t("index.enterRoom"));
  if (input === null) return;          // cancelled
  const room = input.trim();
  if (room === "") {
    store.room = null;
    forceReconnect();
    return;
  }
  if (!/^[A-Za-z0-9_-]{4,64}$/.test(room)) {
    alert(t("index.room.invalid"));
    return;
  }
  store.room = room;
  forceReconnect();
};
```

`forceReconnect()` closes the underlying WebSocket on `store.signaling` (using whatever
close method `SignalingConnection` exposes — add a `close()` shim if needed). The
existing `connectionLoop` in `store.ts` catches the close, loops, and reconnects — passing
the new `store.room` into `SignalingConnection.connect` on its way through. No retry-backoff
change is needed; the loop's existing 5-second retry on error is unchanged.

### Initial population from URL

On mount, before the first `setupConnection`, read `window.location.search`:

```ts
const params = new URLSearchParams(window.location.search);
const initialRoom = params.get("room");
if (initialRoom && /^[A-Za-z0-9_-]{4,64}$/.test(initialRoom)) {
  store.room = initialRoom;
}
```

Invalid values from the URL are ignored silently (no alert on load). The URL is not
written back when the user edits via the prompt; sharing is by manually copying the URL.

### i18n

New keys in `i18n/locales/en.json`:

- `index.room.label` → `"Room"`
- `index.room.none` → `"none"`
- `index.enterRoom` → `"Enter room code (4-64 chars, letters/numbers/_-):"`
- `index.room.invalid` → `"Invalid room code. Use 4-64 of A-Z, a-z, 0-9, _ or -."`

Other locale files only need the keys added empty; the i18n module falls back to the
default locale for missing strings. Translation is out of scope for this change — leave
non-en files with the keys added (so translators have a placeholder) or untouched
(translators add the keys later). Implementer's call.

## Compatibility

| Combination                       | Behavior                                                                  |
|-----------------------------------|---------------------------------------------------------------------------|
| Old web build → new server        | No `room` sent; server falls through to IP grouping. Unchanged.           |
| Native rust client → new server   | No `room` sent (the client doesn't know about it); IP grouping. Unchanged. |
| New web build → old server        | Server ignores unknown query param (axum `Query` is lenient). UI badge says "Room: X" but peers are actually IP-grouped. Documented wart. |
| New web build, no `room` set      | Identical to old web build's behavior.                                     |

## Security notes

- Anyone who has the room code can enter the room. Treat codes the way you'd treat a
  Google Meet link — secret-ish, share over a trusted channel.
- DDoS rate limits remain IP-keyed, not room-keyed. A single attacker who burns through
  their per-IP MAX_REQUESTS hits the limit regardless of how many rooms they tried.
- `MAX_CONNECTIONS_PER_IP` is per-IP, not per-room. Attackers can't DoS a specific room
  without burning their own IP's connection budget.
- The server never logs the room code at INFO level; if logging is desired for debugging,
  add it at DEBUG and remember room codes may be user-secret.

## Files touched

**localsend-server**
- `server/src/controller/ws_controller.rs`
- `server/src/util/room.rs` (new)
- `server/src/util/mod.rs`

**localsend-web**
- `app/services/signaling.ts`
- `app/services/store.ts`
- `app/pages/index.vue`
- `i18n/locales/en.json`

## Open questions / explicit deferrals

- **URL writeback on room edit.** Deferred. PIN doesn't write to URL; matching that
  for consistency. A "Copy share URL" button can be added in a follow-up.
- **Non-en translations.** Deferred. Implementer adds keys to other locale files
  empty if they want translators to see them, otherwise leaves them alone.
- **QR / sharing UX.** Deferred.
