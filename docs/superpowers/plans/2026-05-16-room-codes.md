# Room-code Peer Grouping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional `room` query parameter to the signaling WebSocket so peers with the same code see each other regardless of IP family (fixes dual-stack v4↔v6 isolation).

**Architecture:** Server splits the existing IP-based key into two — `peer_group` (visibility) and `rate_limit_key` (DDoS accounting). When a client passes `?room=<code>`, the server uses `room:<code>` as `peer_group`, otherwise it falls back to the existing IP group. The web client adds a small "Room" UI matching the existing PIN pattern; setting/clearing the room closes the signaling socket so the reconnect loop picks up the new value.

**Tech Stack:** Rust (axum WebSockets), TypeScript / Vue 3 / Nuxt 4, vitest, cargo test.

**Spec:** `localsend-server/docs/superpowers/specs/2026-05-16-room-codes-design.md`

**Working dirs:**
- Server: `/home/ubuntu/project/localsend/localsend-server` (separate git repo)
- Web: `/home/ubuntu/project/localsend/localsend-web` (separate git repo)

**Commit identity:** This environment has no git identity configured. The implementer should set one (`git config user.name` / `user.email`) in each repo before the first commit, or pass identity per-commit via `GIT_AUTHOR_*` / `GIT_COMMITTER_*` env vars. The commit messages below are correct; the identity is the implementer's call.

## File structure

**localsend-server:**
- Create: `server/src/util/room.rs` — validation of room codes, with unit tests
- Modify: `server/src/util/mod.rs` — export the new module
- Modify: `server/src/controller/ws_controller.rs` — split keys, read & validate `room` param

**localsend-web:**
- Create: `app/utils/room.ts` — single regex helper for client-side validation
- Create: `app/utils/room.test.ts` — vitest cases for the helper
- Modify: `app/services/signaling.ts` — accept `room` in `connect`, expose `close()`
- Modify: `app/services/store.ts` — add `store.room`, thread through reconnect loop
- Modify: `app/pages/index.vue` — Room column UI, click handler, URL-param init
- Modify: `i18n/locales/en.json` — four new keys

---

## Task 1: Server — `validate_room_code` module (TDD)

**Files:**
- Create: `localsend-server/server/src/util/room.rs`
- Modify: `localsend-server/server/src/util/mod.rs`

- [ ] **Step 1: Write the failing tests + the module skeleton (test-first)**

Create `localsend-server/server/src/util/room.rs`:

```rust
/// Validates a room code per the protocol rules:
/// - 4..=64 characters
/// - charset `[A-Za-z0-9_-]` (no whitespace, no trimming)
///
/// Returns `Ok(s)` on success, `Err(())` on any violation.
pub(crate) fn validate_room_code(s: &str) -> Result<&str, ()> {
    Err(()) // intentionally fails every case to drive the tests
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_valid_codes() {
        assert!(validate_room_code("abcd").is_ok());
        assert!(validate_room_code("ABC-123_xyz").is_ok());
        assert!(validate_room_code(&"a".repeat(64)).is_ok());
        assert!(validate_room_code("a-_0Z").is_ok());
    }

    #[test]
    fn rejects_too_short() {
        assert!(validate_room_code("").is_err());
        assert!(validate_room_code("abc").is_err());
    }

    #[test]
    fn rejects_too_long() {
        assert!(validate_room_code(&"a".repeat(65)).is_err());
    }

    #[test]
    fn rejects_invalid_chars() {
        assert!(validate_room_code("abc d").is_err()); // mid space
        assert!(validate_room_code(" abcd").is_err()); // leading space
        assert!(validate_room_code("abcd ").is_err()); // trailing space
        assert!(validate_room_code("abc.def").is_err());
        assert!(validate_room_code("abc/def").is_err());
        assert!(validate_room_code("abc:def").is_err());
        assert!(validate_room_code("abc=def").is_err());
        assert!(validate_room_code("abc\tdef").is_err());
    }
}
```

Modify `localsend-server/server/src/util/mod.rs` to add the module. Read the file first to see current contents, then add `pub mod room;` alongside the existing module declarations.

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd /home/ubuntu/project/localsend/localsend-server/server
cargo test --bin server room
```

Expected: All four tests fail (the stub returns `Err(())` for everything, so `accepts_valid_codes` fails first).

- [ ] **Step 3: Implement `validate_room_code`**

Replace the stub body with:

```rust
pub(crate) fn validate_room_code(s: &str) -> Result<&str, ()> {
    let len = s.len();
    if !(4..=64).contains(&len) {
        return Err(());
    }
    if !s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return Err(());
    }
    Ok(s)
}
```

(Note: `s.len()` is byte length, which equals character count here because the charset is pure ASCII — any non-ASCII char fails the charset check on the same input.)

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd /home/ubuntu/project/localsend/localsend-server/server
cargo test --bin server room
```

Expected: All four tests pass. Also run `cargo build` to confirm no warnings break the build.

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/project/localsend/localsend-server
git add server/src/util/room.rs server/src/util/mod.rs
git commit -m "feat(server): add validate_room_code with unit tests"
```

---

## Task 2: Server — Split `handle_socket` keys (refactor, no behavior change)

**Files:**
- Modify: `localsend-server/server/src/controller/ws_controller.rs`

The current signature couples peer visibility and rate-limit accounting under one `ip_group`. Split into two parameters now (both still computed from the same IP, so behavior is identical), making the next task a one-line wiring change.

- [ ] **Step 1: Read the current file**

Open `localsend-server/server/src/controller/ws_controller.rs`. Confirm `handle_socket` signature is:

```rust
async fn handle_socket(
    tx_map: TxMap,
    request_count_map: IpRequestCountMap,
    socket: WebSocket,
    ip_group: String,
    peer: ClientInfo,
)
```

If the signature differs, stop and inspect — the plan was written against the current state.

- [ ] **Step 2: Edit the signature and internals**

Change `handle_socket` to take two keys:

```rust
async fn handle_socket(
    tx_map: TxMap,
    request_count_map: IpRequestCountMap,
    socket: WebSocket,
    peer_group: String,
    rate_limit_key: String,
    peer: ClientInfo,
)
```

Inside the function, rename every use of `ip_group` to `peer_group`. Then for each `protect_ddos_request_count(&request_count_map, &<key>)` call, replace `<key>` with `rate_limit_key` (or its clone). Specifically:

- The `'lock:` block: `tx_map.entry(ip_group.clone())` → `tx_map.entry(peer_group.clone())`; `protect_ddos_request_count(&request_count_map, &ip_group)` → `protect_ddos_request_count(&request_count_map, &rate_limit_key)`.
- The `Connect:` `tracing::info!` line: extend it to include both keys, e.g.:
  ```rust
  tracing::info!(
      "Connect: peer_group={peer_group} rate_limit_key={rate_limit_key} / {peer_id} (active: {debug_active_connections}, total active: {debug_total_active_connections})"
  );
  ```
- The receive-task closure setup: introduce a `let rate_limit_key_clone = rate_limit_key.clone();` next to the existing `let ip_group_clone = ip_group.clone();`. Rename `ip_group_clone` to `peer_group_clone`. Inside the closure, the `protect_ddos_request_count(&request_count_map, &ip_group_clone)` call becomes `protect_ddos_request_count(&request_count_map, &rate_limit_key_clone)`.
- The `send_update_to_other_peers_with_lock(...&ip_group_clone...)` and `send_to_peer_with_lock(...&ip_group_clone...)` calls pass `&peer_group_clone` (these helpers look up in `tx_map`, so they use the peer-group key).
- The cleanup block at the end of `handle_socket`: `tx_map.get_mut(&ip_group)` → `tx_map.get_mut(&peer_group)`; `tx_map.remove(&ip_group)` → `tx_map.remove(&peer_group)`. The `Disconnect:` log line stays focused on `peer_id`; no key needed.

The helper functions `send_update_to_other_peers_with_lock` and `send_to_peer_with_lock` already take `ip_group: &str`. Rename that parameter to `peer_group: &str` in each helper for consistency, and update internal `tx_map.get_mut(ip_group)` / `tx_map.get(ip_group)` calls accordingly.

- [ ] **Step 3: Update `ws_handler` to pass both keys (both = ip_group for now)**

In `ws_handler`, change:

```rust
Ok(ws.on_upgrade(move |socket| {
    handle_socket(
        state.tx_map,
        state.request_count_map,
        socket,
        get_ip_group(ip),
        peer_info,
    )
}))
```

to:

```rust
let rate_limit_key = get_ip_group(ip);
let peer_group = rate_limit_key.clone();
Ok(ws.on_upgrade(move |socket| {
    handle_socket(
        state.tx_map,
        state.request_count_map,
        socket,
        peer_group,
        rate_limit_key,
        peer_info,
    )
}))
```

- [ ] **Step 4: Compile**

```bash
cd /home/ubuntu/project/localsend/localsend-server/server
cargo build
cargo test --bin server
```

Expected: clean build, all existing tests still pass (the only tests today are in `util/ip.rs` and the new `util/room.rs`; this task touches neither).

- [ ] **Step 5: Smoke-test by hand (optional but fast)**

```bash
cargo run --release &
SERVER_PID=$!
sleep 2
# Make any malformed WS request to confirm the handler still rejects it.
curl -i 'http://127.0.0.1:3000/v1/ws?d=invalid' 2>&1 | head -5
kill $SERVER_PID
```

Expected: 400 Bad Request (same as before).

- [ ] **Step 6: Commit**

```bash
cd /home/ubuntu/project/localsend/localsend-server
git add server/src/controller/ws_controller.rs
git commit -m "refactor(server): split handle_socket into peer_group + rate_limit_key

No behavior change. Preparing for room-code peer grouping."
```

---

## Task 3: Server — Wire `room` query param through `ws_handler`

**Files:**
- Modify: `localsend-server/server/src/controller/ws_controller.rs`

- [ ] **Step 1: Add `room` to `WsQuery`**

Edit the struct:

```rust
#[derive(Deserialize)]
pub struct WsQuery {
    /// `PeerRegisterDto` encoded as base64.
    pub d: String,
    /// Optional room code. If present, peers with the same code form one
    /// visibility group regardless of IP. Validated per `util::room`.
    pub room: Option<String>,
}
```

- [ ] **Step 2: Import the validator and use it in `ws_handler`**

Add to the existing `use crate::util...` lines:

```rust
use crate::util::room::validate_room_code;
```

Replace the `peer_group` / `rate_limit_key` computation (from Task 2 step 3) with:

```rust
let rate_limit_key = get_ip_group(ip);
let peer_group = match payload.room.as_deref() {
    Some(code) => {
        validate_room_code(code)
            .map_err(|_| AppError::status(StatusCode::BAD_REQUEST, None))?;
        format!("room:{code}")
    }
    None => rate_limit_key.clone(),
};
```

(The `format!("room:{code}")` prefix prevents collision between a room named `1.2.3.4` and an actual IP group `1.2.3.4`.)

- [ ] **Step 3: Compile**

```bash
cd /home/ubuntu/project/localsend/localsend-server/server
cargo build
cargo test --bin server
```

Expected: clean build, all tests pass.

- [ ] **Step 4: End-to-end smoke test (manual, requires `websocat` or similar)**

Install if missing: `cargo install websocat` — or skip this step and rely on the end-to-end browser test in Task 9. To verify the room param is parsed:

```bash
cd /home/ubuntu/project/localsend/localsend-server/server
cargo run --release &
SERVER_PID=$!
sleep 2

# 1. Valid base64-encoded register DTO. The exact contents don't matter for
#    this test; we only care about the room-param handling. Use any valid DTO.
DTO=$(printf '{"alias":"test","version":"2.3","deviceType":"WEB","token":"x"}' | base64 -w0 | tr -d '=' | tr '+/' '-_')

# 2. Invalid room — too short. Should 400.
curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:3000/v1/ws?d=${DTO}&room=abc"
# Expected: 400

# 3. Invalid room — bad char. Should 400.
curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:3000/v1/ws?d=${DTO}&room=abc.def"
# Expected: 400

# 4. Valid room. Should attempt a WS upgrade — curl will return 400 because
#    it's not actually doing the upgrade, but the upgrade error code is 426
#    "Upgrade Required" not 400, so distinguish by message. Easier: use websocat.
echo '' | websocat --max-messages 1 "ws://127.0.0.1:3000/v1/ws?d=${DTO}&room=movie-night" || true
# Expected: connection accepted, then closed by the server's protocol (the
# register-DTO above isn't a real peer fingerprint, so it may fail at the
# protocol layer — but it must not fail at the room-validation layer).

kill $SERVER_PID
```

Acceptance for this task: the two 400 cases return 400; the valid case does not return 400 from the room validation.

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/project/localsend/localsend-server
git add server/src/controller/ws_controller.rs
git commit -m "feat(server): accept optional room query param for peer grouping

Adds ?room=<code> to /v1/ws. When present and valid, peers in the
same room form one visibility group regardless of IP family. Falls
back to existing IP-based grouping when absent."
```

---

## Task 4: Web — `isValidRoomCode` helper (TDD)

**Files:**
- Create: `localsend-web/app/utils/room.ts`
- Create: `localsend-web/app/utils/room.test.ts`

- [ ] **Step 1: Write the failing test**

Create `localsend-web/app/utils/room.test.ts`:

```ts
import { expect, test } from "vitest";
import { isValidRoomCode } from "./room";

test("accepts valid codes", () => {
  expect(isValidRoomCode("abcd")).toBe(true);
  expect(isValidRoomCode("ABC-123_xyz")).toBe(true);
  expect(isValidRoomCode("a".repeat(64))).toBe(true);
  expect(isValidRoomCode("a-_0Z")).toBe(true);
});

test("rejects too short", () => {
  expect(isValidRoomCode("")).toBe(false);
  expect(isValidRoomCode("abc")).toBe(false);
});

test("rejects too long", () => {
  expect(isValidRoomCode("a".repeat(65))).toBe(false);
});

test("rejects invalid chars", () => {
  expect(isValidRoomCode("abc d")).toBe(false);
  expect(isValidRoomCode(" abcd")).toBe(false);
  expect(isValidRoomCode("abcd ")).toBe(false);
  expect(isValidRoomCode("abc.def")).toBe(false);
  expect(isValidRoomCode("abc/def")).toBe(false);
  expect(isValidRoomCode("abc:def")).toBe(false);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /home/ubuntu/project/localsend/localsend-web
pnpm exec vitest run app/utils/room.test.ts
```

Expected: FAIL with "Cannot find module './room'" or similar.

- [ ] **Step 3: Implement the helper**

Create `localsend-web/app/utils/room.ts`:

```ts
const ROOM_CODE_RE = /^[A-Za-z0-9_-]{4,64}$/;

export function isValidRoomCode(s: string): boolean {
  return ROOM_CODE_RE.test(s);
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /home/ubuntu/project/localsend/localsend-web
pnpm exec vitest run app/utils/room.test.ts
```

Expected: PASS, all four tests green.

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/project/localsend/localsend-web
git add app/utils/room.ts app/utils/room.test.ts
git commit -m "feat(web): add isValidRoomCode utility"
```

---

## Task 5: Web — `SignalingConnection` accepts room + exposes `close()`

**Files:**
- Modify: `localsend-web/app/services/signaling.ts`

- [ ] **Step 1: Extend `connect` to accept `room`**

In `localsend-web/app/services/signaling.ts`, change the `connect` signature param destructure to add `room`:

```ts
public static async connect({
  url,
  info,
  room,
  onMessage,
  generateNewInfo,
  onClose,
}: {
  url: string;
  info: ClientInfoWithoutId;
  room?: string | null;
  onMessage: OnMessageCallback;
  generateNewInfo: () => Promise<ClientInfoWithoutId>;
  onClose: () => void;
}): Promise<SignalingConnection> {
```

Then change the URL construction. Replace:

```ts
const ws = new WebSocket(`${url}?d=${encodedInfo}`);
```

with:

```ts
const qs = room
  ? `d=${encodedInfo}&room=${encodeURIComponent(room)}`
  : `d=${encodedInfo}`;
const ws = new WebSocket(`${url}?${qs}`);
```

- [ ] **Step 2: Add `close()` method**

Inside the `SignalingConnection` class, alongside `waitUntilClose`:

```ts
public close(): void {
  this._socket.close();
}
```

- [ ] **Step 3: Compile-check**

```bash
cd /home/ubuntu/project/localsend/localsend-web
pnpm run build  # or `pnpm exec nuxt prepare && pnpm exec vue-tsc --noEmit` if faster
```

Expected: clean build. The new `room` param is optional, so existing callers in `store.ts` still compile.

- [ ] **Step 4: Commit**

```bash
cd /home/ubuntu/project/localsend/localsend-web
git add app/services/signaling.ts
git commit -m "feat(web): SignalingConnection.connect accepts room; expose close()"
```

---

## Task 6: Web — `store.room` + reconnect on change

**Files:**
- Modify: `localsend-web/app/services/store.ts`

- [ ] **Step 1: Add `room` to the reactive store**

In the `store = reactive({...})` block, add a field:

```ts
// Room code for peer grouping (null = use IP-based grouping).
room: null as string | null,
```

Place it adjacent to `pin: null as string | null,` for grouping by purpose.

- [ ] **Step 2: Pass `room` into `SignalingConnection.connect` from the loop**

In `connectionLoop`, the existing `SignalingConnection.connect({...})` call adds `room: store.room` as a new field:

```ts
store.signaling = await SignalingConnection.connect({
  url: url,
  info: store._proposingClient!,
  room: store.room,
  onMessage: (data: WsServerMessage) => {
    // ... unchanged ...
  },
  generateNewInfo: async () => {
    // ... unchanged ...
  },
  onClose: () => {
    // ... unchanged ...
  },
});
```

- [ ] **Step 3: Export a `setRoom` helper**

Add this exported function near `updateAliasState`:

```ts
/**
 * Update the room and force the signaling socket to reconnect so the new
 * room takes effect. Pass null (or "") to clear.
 */
export function setRoom(room: string | null) {
  store.room = room && room.length > 0 ? room : null;
  // Close the current socket; connectionLoop will reconnect with the new room.
  store.signaling?.close();
}
```

- [ ] **Step 4: Compile-check**

```bash
cd /home/ubuntu/project/localsend/localsend-web
pnpm run build
```

Expected: clean build.

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/project/localsend/localsend-web
git add app/services/store.ts
git commit -m "feat(web): plumb room through connection loop + setRoom helper"
```

---

## Task 7: Web — i18n keys

**Files:**
- Modify: `localsend-web/i18n/locales/en.json`

- [ ] **Step 1: Read the current file**

Read `localsend-web/i18n/locales/en.json` and locate the `"index"` object. Inside it there's a `"pin"` sub-object. The new keys mirror that structure.

- [ ] **Step 2: Add the new keys**

Inside the `"index"` object, add a sibling `"room"` sub-object and an `"enterRoom"` key alongside the existing `"enterPin"`. The required keys:

```json
"room": {
  "label": "Room",
  "none": "none",
  "invalid": "Invalid room code. Use 4-64 of A-Z, a-z, 0-9, _ or -."
},
"enterRoom": "Enter room code (4-64 chars, letters/numbers/_-):"
```

Insert them so the JSON remains valid (mind the trailing commas in the surrounding object). Do not modify other locale files in this task — they fall back to English when keys are missing.

- [ ] **Step 3: Verify JSON parses**

```bash
cd /home/ubuntu/project/localsend/localsend-web
node -e "JSON.parse(require('fs').readFileSync('i18n/locales/en.json', 'utf8')); console.log('ok')"
```

Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
cd /home/ubuntu/project/localsend/localsend-web
git add i18n/locales/en.json
git commit -m "i18n(web): add room and enterRoom keys (en)"
```

---

## Task 8: Web — Room UI in `index.vue`

**Files:**
- Modify: `localsend-web/app/pages/index.vue`

- [ ] **Step 1: Import `setRoom` and `isValidRoomCode`**

Update the existing import from `@/services/store`:

```ts
import {
  setupConnection,
  startSendSession,
  store,
  updateAliasState,
  setRoom,
} from "@/services/store";
```

Add a new import near the other utility imports:

```ts
import { isValidRoomCode } from "~/utils/room";
```

- [ ] **Step 2: Add the Room column to the header strip**

The current header strip in the `<template>` has two columns ("You" and "PIN") separated by a vertical divider. Add a third column with an identical separator, mirroring the PIN block. After the existing PIN `<div class="pr-2">...</div>`, insert:

```vue
<div
  class="inline-block h-12 w-[2px] bg-gray-300 dark:bg-gray-700 mx-4"
></div>

<div class="pr-2">
  <span>
    {{ t("index.room.label") }}
  </span>
  <br />
  <span class="font-bold cursor-pointer" @click="updateRoom">
    {{ store.room ?? t("index.room.none") }}
  </span>
</div>
```

- [ ] **Step 3: Add the `updateRoom` handler**

In the `<script setup>` block, near `updatePIN`, add:

```ts
const updateRoom = async () => {
  const input = prompt(t("index.enterRoom"), store.room ?? "");
  if (input === null) return; // user cancelled
  const trimmed = input.trim();
  if (trimmed === "") {
    setRoom(null);
    return;
  }
  if (!isValidRoomCode(trimmed)) {
    alert(t("index.room.invalid"));
    return;
  }
  setRoom(trimmed);
};
```

- [ ] **Step 4: Read room from URL on mount**

In the `onMounted` async block, before the existing `await setupConnection({...})` call, add:

```ts
const params = new URLSearchParams(window.location.search);
const initialRoom = params.get("room");
if (initialRoom && isValidRoomCode(initialRoom)) {
  store.room = initialRoom;
}
```

(Set `store.room` directly here — we haven't connected yet, so there's no socket to close.)

- [ ] **Step 5: Build + visually verify in dev**

```bash
cd /home/ubuntu/project/localsend/localsend-web
pnpm run dev
```

Open the dev URL. Expected:
- A third "Room" column appears next to "PIN", value "none".
- Clicking "none" opens a prompt. Entering `test-room-1` updates the value and (in DevTools Network panel) the WS reconnects with `&room=test-room-1` on the query string.
- Refreshing `?room=movie-night` in the URL pre-fills the Room value as `movie-night`.
- Entering `abc` (too short) shows the invalid-code alert and leaves the value unchanged.
- Entering empty string clears the room back to "none" and the WS reconnects without the room param.

- [ ] **Step 6: Run all web tests**

```bash
cd /home/ubuntu/project/localsend/localsend-web
pnpm exec vitest run
```

Expected: all tests pass (the existing base64/streamController tests plus the new room test from Task 4).

- [ ] **Step 7: Commit**

```bash
cd /home/ubuntu/project/localsend/localsend-web
git add app/pages/index.vue
git commit -m "feat(web): add Room column UI + URL param init"
```

---

## Task 9: End-to-end manual verification

This task is **manual** — there is no integration test harness in either repo. Do it before marking the feature done.

**Files:** none (verification only)

- [ ] **Step 1: Build both images and bring the stack up**

```bash
cd /home/ubuntu/project/localsend
docker compose build localsend-web localsend-signaling
docker compose up -d localsend-web localsend-signaling
```

- [ ] **Step 2: Verify the existing IP-grouping path still works**

In two browser windows on the same network (or both behind the same NAT), open the deployed URL without a `?room=` param. Both should appear in each other's peer list as before. **Do not skip this** — Task 2 is a refactor and this is the only safety net.

- [ ] **Step 3: Verify the room path joins cross-stack peers**

On a dual-stack network, open the deployed URL in two browsers. In one, set `?room=test-room-1` via the UI or URL. In the other, set the same. Both should now see each other regardless of which IP family their WS uses.

Concretely:
- Browser A: open `https://your-host/send/?room=test-room-1` — Room column shows `test-room-1`.
- Browser B: open `https://your-host/send/`, click `none` next to Room, type `test-room-1`, confirm.
- Both should reconnect (brief "Connecting..." may flash) and then show each other.

- [ ] **Step 4: Verify cross-room isolation**

Browser A in room `test-room-1`, Browser B in room `test-room-2`. They should NOT see each other.

- [ ] **Step 5: Verify invalid room rejection**

In DevTools Network panel, manually craft a request:

```js
new WebSocket("wss://your-host/send/v1/ws?d=eyJ9&room=abc")
```

(Anything 1-3 chars or with disallowed characters.) Server should respond with HTTP 400 / WS close.

- [ ] **Step 6: Verify rate limiting still keys per-IP**

This is hard to test without a multi-IP setup. At minimum, confirm `MAX_REQUESTS_PER_IP_PER_HOUR` is still being honored: bash-script a tight loop of ~50 register requests from one IP under a room and watch for the existing rate-limit error. Optional but valuable.

- [ ] **Step 7: No commit needed**

This task verifies the previous commits.

---

## Self-review notes

The plan covers every section of the spec:
- Wire-protocol change (room query param) → Task 3
- Server-side two-keys design → Task 2
- Server validation → Task 1
- Web URL plumbing → Tasks 4, 5
- Web state + reconnect → Task 6
- Web UI mirroring PIN → Tasks 7, 8
- i18n keys → Task 7
- Compatibility (server ignores missing room, web ignores missing-room semantics on old server) → falls out of the default-None handling in Task 3; verified manually in Task 9 step 2.
