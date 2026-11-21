# NANNETWORKING — NaN/0S network specification

Status: **living specification**, baseline network sources at `f24ca88` (the
parallel pre-SQLite worktrees do not change this document's baseline). This
sheet describes what is actually wired in the tree, distinguishes it from the
larger planned protocol inventory, and names the gates that prove each layer.

The short version: NaN/0S has a complete **guest-side NANNET control plane**,
a real **N16T v1 frame/session/replay/router** in raw NaN16, real **Android
HTTPS and WiFi host bridges**, and two x86 **bare-metal NIC probes** with a
single-flow ARP/IPv4/ICMP/UDP-DNS/TCP path. It does **not** yet have a resident
multi-socket TCP/IP stack, a live radio driver bound to `wlan0`, or a deployed
NANNET gateway inside this repository.

---

## 1. Layer map

```text
+---------------------------------------------------------------+
| guest C programs, shell, Settings, NANNET service cart        |
+---------------------------------------------------------------+
| NANNET control plane (raw NaN16)                              |
|   links: lo eth0 wlan0 seam0                                  |
|   addresses 16-bit / prefix 0..16, routes, DNS, drivers       |
|   WiFi state machine + deterministic scan fixture             |
|   config apply/rollback generations                           |
+---------------------------------------------------------------+
| N16T v1 (raw NaN16)                                           |
|   32-byte header, 16-byte session, u32 sequence, u32 length   |
|   CRC-32/ISO-HDLC trailer, replay cursor, session transitions |
|   13 message types, point route selection                     |
+---------------------------------------------------------------+
| NANNET global mesh / overbootstrap (raw NaN16)                |
|   nan://GM0:SC0:MC0:BS0:HWn -> local point 1..256             |
|   route address 0xA000 + point, 8 MiB page per point          |
+---------------------------------------------------------------+
| host transport boundary                                        |
|   Android: HTTPS adapter + persistent N16T guest + WifiBridge |
|   x86: NE2000/ RTL8139 under QEMU user-mode networking         |
|   C core: fd stream framing + VM byte staging                 |
+---------------------------------------------------------------+
| byte codecs / CRC32 / FNV-1a / BE-LE lanes / vector runner    |
+---------------------------------------------------------------+
```

The transport is deliberately replaceable. NANNET owns identity, policy, route
selection and session semantics; HTTPS, QEMU user-net and the C fd driver only
move bounded bytes.

---

## 2. Implemented vs planned

| Area | State | Evidence |
|---|---|---|
| NANNET links/addresses/routes/DNS | implemented | `tools/nannet_gate.sh`, `nannet_link_gate.sh` |
| NANNET config apply/rollback | implemented | `nannet_gate.sh` |
| NANNET WiFi state machine | implemented against fixtures | `nannet_wifi_gate.sh` |
| NANNET service console | implemented (slot-less) | `nannet_service_gate.sh` |
| N16T v1 framing/CRC/replay/session | implemented | `tools/train_protocol_gate.sh` |
| N16T Android guest ABI | implemented | `n16t_server_test.nas`, Android CI |
| Android HTTPS adapter | implemented (client primitive) | `N16HttpsTransportTest.kt` |
| Android persistent remote session | implemented (client primitive) | `N16RemoteSession.kt` |
| Android real WiFi scan/join UI | implemented (host side) | `WifiBridge.kt` |
| x86 NE2000 ARP probe | implemented | `x86/tools/netgate.sh` |
| x86 RTL8139 single-flow stack | implemented probe | `tools/nic_gate.sh` |
| NANNET global address parser | implemented | `tools/route_address_gate.sh` |
| overbootstrap point/page/route | implemented | `tools/overbootstrap_route_gate.sh` |
| byte codecs / vector runner | implemented subset | `tools/lanesmoke.sh`, `net_test.nas` |
| head bank/runtime/worker | implemented scratch primitive | `n16_head_*_gate.sh` |
| live NANNET gateway/server | **not in tree** | external Koyeb/NaNROUTER route |
| resident TCP/IP sockets/DHCP/DNS cache | **not implemented** | single-flow probes only |
| live radio driver on `wlan0` | **not implemented** | fixture only |
| QOTD/Finger/Telnet/Gopher/HTTP/HTTPS listeners | **not implemented** | Settings shows `PENDING` |
| full codec/protocol inventory | **mostly planned** | `TODO.md` user network spec |

---

## 3. NANNET control plane (M1/M2/M3)

Source: `src/nannet/nannet.nas` (direct-call library). Console:
`src/nan/nannet_cart.nas`. Settings integration:
`src/exhibits/settings_cart.nas`.

### 3.1 ABI and status codes

`r1..r5` are arguments, `r1/r2` results, `r3` status:

| Code | Meaning |
|---:|---|
| 0 | OK |
| 1 | `EINVAL` |
| 2 | `ENOENT` |
| 3 | `ENOSPC` |
| 4 | `EOVERFLOW` |
| 5 | `EPROTO` |
| 7 | `EPERM` |

### 3.2 Interfaces

Four fixed records `{ifid, name, kind, state, mtu, drvid, mac, flags}`:

| id | name | kind | default state | MTU | default driver |
|---:|---|---|---|---:|---|
| 0 | `lo` | loop | up | 65535 | 9 `DN_LOOP` |
| 1 | `eth0` | wired | down | 1500 | 10 `DN_NULL` |
| 2 | `wlan0` | wifi | down | 1500 | 10 `DN_NULL` |
| 3 | `seam0` | seam | down | 1500 | 10 `DN_NULL` |

States are `down`, `up`, `scan`, `join`, `ok`, `fail`. `nn_link_set`,
`nn_link_up`, `nn_link_down` and `nn_link_list` operate on the table.

### 3.3 Driver registry

The registry is a **load-state table**, not a live protocol dispatch layer.
IDs 1..13 are stable:

| id | name | id | name |
|---:|---|---:|---|
| 1 | `DN_UDP` | 8 | `DN_BLE` |
| 2 | `DN_TCP` | 9 | `DN_LOOP` |
| 3 | `DN_TLS` | 10 | `DN_NULL` |
| 4 | `DN_DNS` | 11 | `DN_REC` |
| 5 | `DN_ICMP` | 12 | `DN_REP` |
| 6 | `DN_WS` | 13 | `DN_SEAM` |
| 7 | `DN_UNIX` | | |

`nn_drv_set(id,0|1)` toggles the load bit; `nn_drv_find` returns the record.

### 3.4 Addresses, routes and DNS

- Address record: `{ifid, ip16, prefix, flags, state}`.
- Route record: `{dst16, prefix, gw16, ifid, metric, state}`.
- DNS record: `{ip16, state}`.
- Addresses are **16-bit**, prefix 0..16. This is the NANNET logical world,
  not IPv4.
- Capacity: **6 addresses, 8 routes, 2 DNS servers, 4 interfaces**.
- `nn_route_lookup` is longest-prefix match and returns gateway, interface and
  status.
- `nn_status` prints `ST` followed by the count of up links, addresses,
  routes and DNS entries.

### 3.5 Config grammar

`nn_cfg_apply` reads a NUL-terminated `.nancfg` text. Keywords are matched by
first letter; numbers are decimal or `0x`:

```text
# comments and blank lines are ignored
link    <ifid> <0|1>
addr    <ifid> <ip16> <prefix 0..16>
route   <dst16> <prefix> <gw16> <ifid> <metric>
dns     <ip16>
driver  <drvid> <0|1>
wscan   <ifid>
wjoin   <ifid> <scan-index>
wleave  <ifid>
```

`src/nannet/system.nancfg` is the sample profile:

```text
link 0 1
link 1 1
link 2 1
addr 1 0x0A00 16
route 0x0000 0 0x0A01 1 1
dns 0x0A01
driver 9 1
driver 10 1
```

Apply is transactional: it snapshots interfaces, addresses, routes, DNS,
WiFi joined state and driver load states, and restores the snapshot on any
error. `nn_cfg_rollback` restores the last apply snapshot; `nn_cfg_status`
reports generation/state.

### 3.6 WiFi

Guest-side WiFi is a deterministic **state-machine fixture**, not a radio
driver:

- states: `down -> scanning -> joining -> joined/failed`
- scan fixture: `HomeNet` RSSI 60, `Cafe` RSSI 42, `Lab` RSSI 30
- `nn_wifi_scan(ifid)`, `nn_wifi_join(ifid,index)`, `nn_wifi_leave(ifid)`,
  `nn_wifi_list`

The Android `WifiBridge` is a separate real host surface (section 5.4); it is
not yet bound to guest `wlan0`.

### 3.7 Identity and service metadata

`nn_identity` exposes:

- hostname: `NaN0S`
- MAC: `02:4E:41:4E:30:53` (locally administered, ASCII `NAN0S`)
- DNS HINFO: `NaN-LATTICE` / `NAN0S`
- TXT: `NaN0S: a temple that boots. NaN != NaN.`
- QOTD quote: `There is a number that isn't one.`
- Finger banner: `Login: nan0s  Name: NaN/0S  Project: NaN0S`
- reserved ports: QOTD 17, Finger 79; no listeners are installed

`nn_services` prints a metadata-only browser catalogue:

```text
CHINET telnet://chinet.com:23
TELEHACK telnet://telehack.com:23
PROLINE telnet://prolinebbs.dyndns.org:23
SDF telnet://sdf.org:23
FLOODGAP gopher://gopher.floodgap.com:70
FIDONET telnet://fidonet.org:23
ETERNAL-SEPTEMBER telnet://eternal-september.org:23
```

These are names/ports, not live sessions.

### 3.8 Consoles

The slot-less service cart `src/nan/nannet_cart.nas` shows links, counters and
the WiFi fixture. Keys: `1`..`4` toggle links, `P` applies the built-in profile
(lo+eth0, `0x0A00/16`, route, DNS, driver 9), `S` scan, `J` join, `L` leave,
`R` rollback, `ESC` exit. It is launched from the SYSTEM menu via
`service:src/nan/nannet_cart.nan` in `tools/carts.txt`.

Settings (slot 9) exposes:

- NANNET manager: link/address/route/DNS counts, link toggles, PCI scan for
  RTL8139, service-manager screen.
- Driver manager: 13-entry registry and load toggles.
- Codec manager: storage codec catalogue (`NSP-7`, `NSP-8`, `NSPF1`, `NSPV1`,
  `BASE64`, `HEX`).
- Service manager: Telnet 23, QOTD 17, Finger 79, Gopher 70, HTTP 80, HTTPS
  443, all marked `TCP PENDING`/`UDP PENDING`/`TLS PENDING`.

### 3.9 Gates

```sh
sh tools/nannet_gate.sh          # apply, lists, lookup, rollback, restore
sh tools/nannet_link_gate.sh     # state, bounds, addr, longest-prefix, DNS
sh tools/nannet_wifi_gate.sh     # scan/join/leave, fixture, config round-trip
sh tools/nannet_service_gate.sh  # slot-less cart, SYSTEM launch, link/WiFi state
```

---

## 4. N16T v1 — the guest-owned frame/session protocol

Source: `src/nannet/train_protocol.nas`. Android wrapper:
`src/nannet/n16t_android_abi.nas`. Guest image:
`src/nannet/n16t_android_guest.nas`.

N16T is the **wire format and session state machine**. Framing, CRC, sequence,
replay, session ownership and route selection are implemented in raw NaN16.
HTTPS/HTTP only carries the resulting opaque bytes.

### 4.1 Frame layout

All integer fields are little-endian. Total frame = `36 + payload_len`.

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | magic `N16T` (`4E 31 36 54`) |
| 4 | 2 | version = 1 |
| 6 | 2 | message type |
| 8 | 16 | session id (opaque) |
| 24 | 4 | sequence (u32) |
| 28 | 4 | payload length (u32) |
| 32 | N | payload, `0..65536` |
| 32+N | 4 | CRC-32/ISO-HDLC over header+payload |

CRC-32/ISO-HDLC uses reflected polynomial `0xEDB88320`, init/final
`0xFFFFFFFF` (the same primitive as `src/net/crc32.nas`).

### 4.2 Message types

| Type | Name | Payload bytes |
|---:|---|---:|
| 1 | `HELLO` | 2 |
| 2 | `CAPABILITIES` | 8 |
| 3 | `BEGIN` | 12 |
| 4 | `CHUNK` | 1..4096 |
| 5 | `END` | 4 |
| 6 | `ACCEPTED` | 4 |
| 7 | `REJECTED` | 4..256 |
| 8 | `STATUS` | 8 |
| 9 | `DIGEST` | 4 |
| 10 | `PROPOSAL` | 8 |
| 11 | `RESULT` | 4 |
| 12 | `HEARTBEAT` | 0 |
| 13 | `CLOSE` | 0 |

Types 12 and 13 are control messages and are not point-addressed. Every other
type carries a 16-bit logical point in the first two payload bytes.

### 4.3 Session state machine

`n16_session_transition(type, payload_len)`:

| State | Meaning |
|---:|---|
| 0 | idle |
| 1 | hello |
| 2 | negotiated |
| 3 | receiving |
| 4 | corpus complete |
| 5 | accepted |
| 6 | candidate digest |
| 7 | merge proposal |
| 8 | terminal |

Transitions are strict: `HELLO` only from idle, `CAPABILITIES` only from hello,
`BEGIN` only from negotiated, `CHUNK` only while receiving, `END` only while
receiving, `ACCEPTED` only after corpus complete, `REJECTED` from any active
state with 4..256 bytes, `STATUS` from states 4..7, `DIGEST` from accepted,
`PROPOSAL` from digest, `RESULT` from proposal. `CLOSE` resets the session only
from an active state and is terminal. Bad transition -> status 1; bad payload
length -> status 2.

### 4.4 Validation and replay rules

`n16_frame_validate(base, bytes) -> type, payload_len, status`:

| Status | Meaning |
|---:|---|
| 0 | valid |
| 1 | bad magic/version/type range |
| 2 | length/bounds mismatch |
| 3 | replay (sequence not greater than cursor) |
| 4 | CRC mismatch |
| 5 | different 128-bit session id while a session is owned |
| 6 | route/transition rollback |

Rules:

- minimum frame 36 bytes; payload <= 65536; frame length exactly
  `36 + payload`.
- session id is locked on the first CRC-valid frame; all later frames in that
  session must carry the same 16 bytes.
- sequence must strictly increase; a rejected route/transition restores the
  previous sequence and session ownership atomically.
- a different session id is rejected without consuming the replay cursor.

### 4.5 Routing

`n16_frame_route(base, bytes)` validates, advances the session transition,
then routes:

- `HEARTBEAT`/`CLOSE`: no point route; returns zero gateway/interface/point.
- other types: payload must be >= 2; first two bytes are the logical point
  (u16 LE), passed to `ob_point_to_route`.
- result: `r1=gateway`, `r2=interface`, `r3=status`, `r4=logical point`.

`ob_point_to_route` maps point 1..256 to route address `0xA000 + point` and
then calls `nn_route_lookup` (section 7).

### 4.6 Guest ABI for Android

Android calls public labels; each entry returns through `HALT`, and the same
VM instance is retained.

| Entry | Inputs | Result |
|---|---|---|
| `n16_android_build` | `r1` out, `r2` type, `r4` payload, `r5` len, `r6` session-id | `r1` frame len, `r2` error, `r3` status |
| `n16_android_advance` | none; commit pending outbound | `r1` state, `r2` error, `r3` status |
| `n16_android_route` | `r1` frame, `r2` bytes | `r1` gateway, `r2` interface, `r3` status, `r4` point |
| `n16_android_abort` | none; abandon unsent | `r3` status |
| `n16_android_reset` | none | clears replay/session/sequence |

Byte-memory mailbox:

| Region | Byte address | Capacity |
|---|---:|---:|
| frame in/out | `0x00100000` | 65,572 |
| payload staging | `0x00120000` | 65,536 |
| session-id staging | `0x00140000` | 16 |

Transactional sequence: build reserves the next sequence, the host sends, and
only a successful HTTPS exchange calls `advance` (commit). A failed exchange
calls `abort` without consuming the sequence. `CLOSE` resets the guest session
and the next outbound sequence starts at one; Android supplies fresh session
entropy.

### 4.7 Server-side handshake peer

`n16_server_exchange` implements only `HELLO` and `CLOSE`:

- `HELLO` is validated/routed; a route result of status 2 is accepted only for
  logical portal point `0xA001` (point 1).
- response is `CAPABILITIES` with the 8-byte payload
  `[point 1 u16 LE][six zero bytes]`.
- advertised training/merge capability bits are **zero**.
- `CLOSE` returns a terminal `CLOSE`.
- any other type -> status 7 (`EPERM`/unsupported).

`src/nannet/n16t_server_test.nas` builds a real HELLO, exercises the server
peer, proves replay rejection, validates the emitted CAPABILITIES CRC/session/
sequence and finishes with `N16 SERVER PASS`.

### 4.8 N16T limits

| Limit | Value |
|---|---:|
| canonical guest payload | 65,536 bytes |
| canonical guest frame | 65,572 bytes |
| C fd boundary payload | 1,048,576 bytes |
| C fd boundary frame | 1,048,612 bytes |
| `NaNNetTlsTransport` payload | 1,048,576 bytes |
| session id | 16 bytes |
| sequence | u32, starts at 1; overflow wraps to 1, CLOSE/reset restarts at 1 |

The canonical guest validator remains the authority: a 1 MiB host-boundary
frame can be moved by the C driver but is rejected by the 64 KiB N16T guest
validator if it exceeds the guest payload limit.

### 4.9 Gates

```sh
sh tools/train_protocol_gate.sh   # frame/CRC/replay/session/route -> N16 PROTOCOL PASS
sh tools/nrun.sh src/nannet/n16t_server_test.nas 3000000 --serial
                                  # -> N16 SERVER PASS
```

`aarch64/android/Makefile test` also runs `tests/test_nannet_driver` (host
socketpair/VM staging boundary).

---

## 5. Android host transport

The Android app is a **byte mover and WiFi surface**. It does not parse N16T
fields; the guest owns all frame/session semantics.

### 5.1 Classes

| File | Responsibility |
|---|---|
| `N16HttpsTransport.kt` | bounded HTTPS POST, canonical media type, bearer auth |
| `N16RemoteSession.kt` | one serialized exchange: build, send, commit, accept |
| `N16GuestProtocol.kt` | persistent NanVm, assets/labels, staging, step budget |
| `NaNNetTlsTransport.kt` | legacy `/n16t` `application/x-n16t` adapter |
| `WifiBridge.kt` | real Android WiFi status/scan/join surface |
| `NanVm.kt` | JNI VM calls incl. stage/extract frame |
| `MainActivity.kt` | endpoint/token entry and WiFi dialogs |

### 5.2 Canonical HTTPS adapter

`N16HttpsTransport(endpoint, bearerToken, connectTimeoutMs=10000,
readTimeoutMs=30000, maxFrameBytes=65572)`:

- endpoint must be `https`, have a host, and contain no user-info/fragment.
- bearer token length 32..512.
- POST with `Authorization: Bearer`, `Content-Type` and `Accept` =
  `application/vnd.nan16.n16t`, `Cache-Control: no-store`, fixed-length stream.
- no redirects; 2xx only; response content type must be exactly the canonical
  media type; response body 36..65,572 bytes.
- reads are bounded; errors are truncated to 256 characters.

### 5.3 Persistent exchange order

`N16RemoteSession` is `@Synchronized` and enforces one in-flight frame:

1. guest `buildFrame(type,payload)` stages payload/session and reserves a
   sequence;
2. HTTPS exchange moves the opaque request frame;
3. only on success `commitSent()` advances the guest transition/sequence;
4. on failure `abortPending()` releases the reservation and the sequence;
5. `acceptPeerFrame(response)` stages, validates and routes in the guest;
6. `closeRemote()` sends terminal type 13 with an empty payload;
7. `resetSession()` resets guest state and rotates session entropy.

`N16GuestProtocol` keeps one `NanVm` for the session, loads
`assets/n16_protocol.nan` and `assets/n16_protocol.labels`, uses
`SecureRandom` for the 16-byte session id, and bounds each guest entry to
12,000,000 steps in 250,000-step slices. Guest memory bases are the N16T
mailbox addresses in section 4.6.

### 5.4 Real WiFi surface

`WifiBridge` uses `WifiManager`/`ConnectivityManager` directly:

- permissions: `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`,
  `ACCESS_NETWORK_STATE`, plus `NEARBY_WIFI_DEVICES` on API 33+ or
  `ACCESS_FINE_LOCATION` below.
- `status()` reports WiFi on/off, SSID, RSSI dBm, link speed or non-WiFi/no
  network.
- `scan()` calls `startScan`, waits 1.6 s, returns sorted SSIDs with security
  class.
- `join()` uses `WifiNetworkSuggestion` on API 29+ (system approval required),
  legacy `WifiConfiguration` below.
- `openSettings()` opens the system WiFi settings.

This is host UI/connectivity only. There is no VpnService/datagram data plane
yet and no binding to guest `wlan0`.

### 5.5 C/JNI byte boundary

`aarch64/android/core/nan_net_driver.c` is transport-only:

- `nan_net_send_frame_fd` / `nan_net_recv_frame_fd`: stream framing over a
  socket; 32-byte header, length from bytes 28..31 (LE u32), 4-byte trailer,
  1 MiB payload cap, exact read/write.
- `nan_net_stage_frame` / `nan_net_extract_frame`: copy a complete frame
  into/out of VM byte memory.
- JNI exposes `stageNetworkFrame` / `extractNetworkFrame`; `NanVm` wraps them.

`tests/test_nannet_driver.c` proves the socketpair round-trip, VM staging and
oversize rejection.

### 5.6 Build and CI

Gradle compiles:

- `src/nannet/n16t_android_guest.nas` -> `assets/n16_protocol.nan`;
- `nmk.awk` labels -> `assets/n16_protocol.labels`.

`.github/workflows/n16-android-transport-tests.yml` assembles
`n16t_server_test.nas`, runs it with `nan_cli`, requires `N16 SERVER PASS`,
then runs `:app:testDebugUnitTest` and `:app:assembleDebug`.
`N16HttpsTransportTest` checks HTTPS-only endpoints, token/frame limits,
user-info/fragment rejection and timeouts.

---

## 6. x86 bare-metal NIC paths

### 6.1 NE2000 ISA probe — `x86/net/ne2k_probe.nas`

Purpose: prove a real guest NIC path under QEMU user-mode networking.

- ISA NE2000 at I/O base `0x300`, IRQ 9 (polled, no IRQ handler).
- MAC `52:54:00:12:34:56`.
- guest `10.0.2.15`; ARP request for gateway `10.0.2.2`.
- verifies ARP reply ethertype/opcode/sender IP; prints `NET PASS`.
- gate: `sh x86/tools/netgate.sh` (skips with 77 if QEMU/ne2k_isa missing).

### 6.2 RTL8139 single-flow probe — `src/nan/nic_cart.nas`

Boot cart at word 8192. PCI function finds `10EC:8139`, enables I/O and bus
mastering, reads BAR0, programs the MAC `02:4E:41:4E:30:53`, RX ring
`0x01000000` and raw TX window `0x01000800`, polled/no IRQ.

Implemented on-wire path:

- Ethernet ARP request/reply.
- IPv4 + ICMP echo request/reply for `10.0.2.2`.
- UDP DNS A query to `10.0.2.3:53` for `example.com`.
- TCP handshake, ACK, 6-byte probe (`NAN0S\n`), echo check, FIN and close
  against QEMU `guestfwd` `10.0.2.100:2323` backed by `/bin/cat`.
- guest source `10.0.2.15`, source port 40000, destination 2323.

`tools/nic_gate.sh` requires exact lines for PCI ID/base/MAC, reset, TX, ARP,
ping, DNS, TCP SYN-ACK/ACK/TX/data/echo/FIN/closed. It loops up to three QEMU
attempts.

### 6.3 QEMU user-mode topology

| Role | Address |
|---|---|
| guest | `10.0.2.15` |
| gateway | `10.0.2.2` |
| DNS | `10.0.2.3` |
| guestfwd TCP | `10.0.2.100:2323` -> host `/bin/cat` |
| NE2000 MAC | `52:54:00:12:34:56` |
| RTL8139 MAC | `02:4E:41:4E:30:53` |

QEMU user-mode networking carries the host's active connection (WiFi or
wired). The guest does not own the radio.

Limits: single flow, polled, no IRQ, no ARP cache, no DHCP, no retransmission/
congestion state, not resident, not bound to NANNET `eth0`, no TLS. It is a
bring-up/probe, not a general stack.

---

## 7. NANNET global mesh and overbootstrap addressing

Sources: `docs/NANNET_GLOBAL_ADDRESSING.md`, `src/nannet/overbootstrap_route.nas`,
`src/nannet/route_address.nas`, `src/nannet/object_key_decode.nas`,
`src/nannet/route_object_resolve.nas`.

### 7.1 Canonical identity

```text
nan://GM0:SC0:MC0:BS0:HW0
```

Five decimal coordinates, each 0..255:

- `GM`: global mesh
- `SC`: supercluster
- `MC`: macrocluster
- `BS`: bootstrap universe
- `HW`: hardware endpoint within the bootstrap universe

Initial assignments in `GM0/SC0/MC0/BS0`:

| HW | Endpoint | Local point |
|---:|---|---:|
| 0 | NaNLMind six-runner GitHub runner ring | 1 |
| 1 | Android / NaNLMind_android | 2 |
| 2 | Hermes | 3 |
| 3 | Clocked | 4 |

`HWn` maps to local overbootstrap point `n+1` (1..256).

### 7.2 Overbootstrap translation

- point 1..256 -> page 0..255.
- page size: **8 MiB**; address space: **2 GiB**.
- role: point 1 runner, point 2 Android, other points reserved/0.
- `ob_point_to_addr(point, offset, length)` returns an absolute byte address;
  offset/length must fit inside one 8 MiB page.
- `ob_point_to_route(point)` returns route address `0xA000 + point` and then
  performs `nn_route_lookup`.

### 7.3 Route-address and object-key grammar

`nmr_addr_parse` accepts:

```text
nan://GM0:SC0:MC0:BS0:HW0::HW0:<point>::vector<id>
nan://GM0:SC0:MC0:BS0:HW0::HW0:<point>::hypergraph<id>
```

- point: 1..255; 0 and 256 are reserved/out-of-range.
- the current parser literal prefix is
  `nan://GM0:SC0:MC0:BS0:HW0::HW0:`; the other HW coordinates in the initial
  map are identity coordinates, not yet accepted by this parser routine.
- key kinds: `vector` (kind 4) and `hypergraph` (kind 8).
- id: 1..9999.
- status: 0 success, 1 malformed, 2 reserved/out-of-range point, 3 empty key.
- key decode: 0 success, 1 malformed/unknown kind, 2 invalid id.
- `nmr_route_resolve`: 0 success, 1/2 key error, 3 object missing, 4 kind
  mismatch, 5 owner-point mismatch.

Examples from the regression suite:

```text
nan://GM0:SC0:MC0:BS0:HW0::HW0:1::vector1337
nan://GM0:SC0:MC0:BS0:HW0::HW0:255::hypergraph42
```

### 7.4 NANNET HTTPS origin and route intake

Per `docs/NANNET_GLOBAL_ADDRESSING.md`:

- the Koyeb NANNET HTTPS origin is a **replaceable transport ingress**; it is
  not the NaN address and must not be encoded as fixed IPv4.
- a bearer token is issued by NANNET and bound to one canonical NaN address.
- clients may send `X-NaN-Address` as a consistency claim; a mismatch with the
  token binding is rejected. The address alone is never authentication.
- NANNET authenticates the HTTPS caller, binds the address, applies route
  policy and relays opaque N16T frames to a trusted peer. It does not inspect
  CRC/sequence/session/route payload.
- accepted media types: legacy `application/x-n16t` and canonical
  `application/vnd.nan16.n16t`; forwarding uses the canonical vendor type.
- route-diff metadata path: `POST /v1/intake/route` with an endpoint token
  bound to `nan://GM0:SC0:MC0:BS0:HW1` and `X-NaN-Address`; NANNET checks the
  digest and local point 2, stores it as **pending unverified evidence**, and
  does not alter the bootstrap map or head state. The six-runner canonical ring
  remains the only writer of bootstrap training state.

### 7.5 Invariants

1. Never trust a client-supplied address without checking its bearer binding.
2. Never use IP/DNS address as logical identity.
3. Keep GM/SC/MC/BS/HW as separate coordinates.
4. Keep global address separate from local 1..256 overbootstrap point.
5. Endpoint intake is evidence-only; only the independent validator approves
   corpus data and only the canonical runner commits learning.
6. Clocked may be a cooperative corpus participant; macrocluster promotion is
   a later topology operation, not a credential shortcut.

N16T v1 still carries only the 16-bit local point in its route payload. The
authenticated NANNET session supplies the global address and translates it to
the local point. A future wire envelope must be versioned and tested without
changing v1 payload interpretation.

---

## 8. Byte codecs and lane primitives

Sources: `src/net/*.nas`. The larger protocol field inventory is in `TODO.md`
under the user network spec (0x01..0x0E); only the codecs below are currently
implemented.

### 8.1 ABI and return word

Codec ABI:

```text
r1 = input byte address
r2 = input length
r3 = output byte address
r4 = output capacity
r5/r6 = codec-specific configuration
r5 = return word = (error << 16) | value
```

`value` is bytes produced on success, bytes required on `ENOSPC` (saturated to
0xFFFF), or 0 on other errors. Codecs clobber only `r1..r8`; `r9..r12` are
reserved for the vector runner.

Error halves in `src/net/defs.nas`:

| Error | Value |
|---|---:|
| OK | 0 |
| `EAGAIN` | -1 |
| `EIO` | -2 |
| `EINVAL` | -3 |
| `ENOTSUP` | -4 |
| `ETIMEDOUT` | -5 |
| `ECLOSED` | -6 |
| `EFAULT` | -7 |
| `ENOSPC` | -8 |
| `EPERM` | -9 |
| `EPROTO` | -10 |
| `EBADENDIAN` | -11 |
| `EBADTAG` | -12 |
| `EOVERFLOW` | -13 |
| `EEMPTY` | -14 |
| `ECRC` | -15 |

### 8.2 Implemented

| File | Codec / primitive |
|---|---|
| `bytes.nas` | BE/LE 16/24/32 lane read/write, byte order helpers |
| `crc32.nas` | CRC-32/ISO-HDLC (reflected `0xEDB88320`), table/update/final |
| `fnv.nas` | FNV-1a 32-bit |
| `hex.nas` | lowercase hex, 2 chars/byte |
| `b64.nas` | Base64url RFC 4648 §5, no padding, strict decode |
| `base32.nas` | Base32 RFC 4648 §6, `=` padding, strict decode |
| `xor.nas` | XOR-chain stream, `c[i]=p[i]^key[i%k]^c[i-1]` |
| `chunk.nas` | chunk split with one-byte piece-length prefix |
| `vec.nas` | table-driven codec vector runner |

`src/tests/net_test.nas` covers CRC-32 known answer, FNV-1a, 64-bit tag swap,
BE lane round-trip and a 22-vector codec table. `src/nan/netcart.nas` is the
large lane-engine self-check cart; `tools/lanesmoke.sh` requires 150+ lines
with no ` NO` result and final `PASS`; `tools/lanegate.sh` compares an exact
private sample digest when present.

### 8.3 Planned, not implemented

The user network spec lists field codecs for L2/L3/L4, DNS, remote access, web,
mail, storage and codecs. Not implemented in this tree include BASE85, QP,
ZLIB, LZ4, BIT_PACK, ROT_N, SYMBOL_MAP, TIMING_PAD, SIZE_PAD, ORDER_PAD and
most protocol-field encoders/decoders. Do not infer them from the Settings
codec catalogue: that screen lists storage codecs, not a live network stack.

---

## 9. Distributed head / runner / training boundary

This layer is present but deliberately **scratch/primitive**, not a live
distributed training service.

### 9.1 N16T training state machine

`train_protocol.nas` defines the corpus/training message set and strict
payload lengths in section 4.2/4.3. The Android server handshake peer
advertises **zero** training/merge capabilities; it only negotiates
HELLO/CAPABILITIES/CLOSE. There is no live NANNET merge, model promotion or
candidate acceptance service in this tree.

### 9.2 Head bank

`src/nannet/n16_head_store.nas`:

- 255 logical heads; head 0 is `NANNET0` and is never learnable.
- global header 8 words; head `n` at `base + 8 + (n-1)*266`.
- two 133-word slots per head; each slot
  `[magic, head, generation, checksum, commit] + 128 raw NaN16 words`.
- `NH_WORDS = 67,838` words (542,704 bytes) plus a 1 KiB staging buffer.
- checksum covers payload and class nibble; commit is written last; torn
  publish keeps the prior generation.
- generation capped at `0x7fffffff`; no implicit reformat; outer storage must
  use SHA-256 for adversarial bytes.

### 9.3 Runtime and worker

`src/nannet/n16_head_runtime.nas` exposes attach/detach/read/observe over one
attached bank. `nhr_observe(head,feature 0..127,increment 1..255,staging)`
updates empirical counters only; no MTH transformation, proof, dispatch or
global merge is implied. Head 0 is rejected. A failed read copies nothing.

`src/nannet/n16_head_worker.nas` wraps the store/runtime as one host-callable
NaN16 image. The transport must copy the HERMES chart's 67,838 raw words with
a class-preserving 8-byte-word API, not the byte API; scratch is at word
`0x1000`/`0x2000`, bank at `0x4000`. The worker contract and labels are gated
by `tools/n16_head_worker_gate.sh`; a live authenticated lease/attachment is
separate work.

### 9.4 Runner task ledger

`src/nannet/runner_task.nas` is a 16-entry bounded task ledger. Task record is
15 words: id, epoch, checkpoint, runner, logical point, operation, input
digest, scratch words, step budget, time budget, expiry epoch, state, output
digest, trace digest, claim epoch. States: empty, queued, claimed, completed.
Statuses cover invalid, full, duplicate, runner/epoch mismatch, invalid state/
replay, expired. `tools/runner_task_gate.sh` and
`tools/runner_ring_integration_gate.sh` exercise it.

### 9.5 Training gates

`nannet-train.sh` / `n16_train_gate.sh` exercise a **local** corpus trainer
(`N16 TRAIN PASS`, candidate `.nan1`), not a network service. The network
training message types exist in N16T, but the server peer currently advertises
zero capabilities.

---

## 10. Gate map

| Command | Requires |
|---|---|
| `sh tools/nannet_gate.sh` | NANNET apply/lists/lookup/rollback |
| `sh tools/nannet_link_gate.sh` | link/address/route/DNS bounds |
| `sh tools/nannet_wifi_gate.sh` | WiFi fixture state machine |
| `sh tools/nannet_service_gate.sh` | built image, service cart, link/WiFi UI |
| `sh tools/train_protocol_gate.sh` | N16T frame/CRC/replay/session/route |
| `sh tools/nrun.sh src/nannet/n16t_server_test.nas 3000000 --serial` | N16T server HELLO/CAPABILITIES/CLOSE |
| `sh tools/route_address_gate.sh` | canonical `nan://...` parser |
| `sh tools/object_key_decode_gate.sh` | vector/hypergraph key decode |
| `sh tools/route_object_resolve_gate.sh` | registry owner/kind resolution |
| `sh tools/overbootstrap_route_gate.sh` | point/page/address/route |
| `sh tools/mirror_pair_gate.sh` | mirror pair map |
| `sh tools/runner_task_gate.sh` | bounded task ledger |
| `sh tools/runner_ring_integration_gate.sh` | runner ring integration |
| `sh tools/n16_head_store_gate.sh` | 255-head double-buffered bank |
| `sh tools/n16_head_runtime_gate.sh` | attach/read/observe/recover |
| `sh tools/n16_head_worker_gate.sh` | host-callable worker labels/image |
| `sh tools/n16_raw_head_gate.sh` | host raw transport + native gate |
| `sh tools/n16_train_gate.sh` | local corpus trainer (not network) |
| `sh tools/lanesmoke.sh` | codec/vector self-check |
| `sh tools/lanegate.sh` | exact private sample (SKIP if absent) |
| `sh tools/nic_gate.sh` | RTL8139 + QEMU guestfwd single-flow stack |
| `sh x86/tools/netgate.sh` | NE2000 + QEMU user-net ARP |
| `make -C aarch64/android test` | C core + `test_nannet_driver` |
| `gradle -p aarch64/android :app:testDebugUnitTest :app:assembleDebug` | Android transport tests/APK |

Android CI: `.github/workflows/n16-android-transport-tests.yml`.
Head CI: `.github/workflows/n16-head-runtime.yml`,
`n16-head-worker.yml`, `n16-head-scratch.yml`, `n16-hermes-head-e2e.yml`.

---

## 11. Honest limits

- **No resident sockets.** There is no `socket()`/`connect()`/`listen()` guest
  API, no file-descriptor table, no multi-connection TCP state machine, no
  retransmission/congestion/window management.
- **No guest TCP/TLS.** The RTL8139 probe implements one handshake/echo/FIN;
  TLS terminates at the Android/host HTTPS boundary.
- **No DHCP or DNS cache.** The x86 probe uses static `10.0.2.15` and a single
  DNS A query. NANNET has DNS server records, not a resolver.
- **No live radio.** Guest WiFi is a deterministic fixture. Android `WifiBridge`
  is real host UI/connectivity but has no VpnService/datagram data plane and is
  not bound to guest `wlan0`.
- **No live NANNET gateway in this repo.** The Koyeb origin, NaNROUTER,
  HERMES and their Python services are external. A successful APK build is not
  evidence of a deployed remote service.
- **N16T v1 is point-addressed, not globally addressed.** The frame carries a
  16-bit local point; the global five-coordinate address is an authenticated
  session/NANNET concept until a versioned envelope exists.
- **Payload-limit mismatch at the boundary.** Guest N16T is 64 KiB; the C fd
  driver and legacy `NaNNetTlsTransport` permit 1 MiB. The guest validator
  remains authoritative.
- **Service listeners pending.** QOTD 17, Finger 79, Telnet 23, Gopher 70,
  HTTP 80 and HTTPS 443 are metadata/`PENDING` entries, not listeners.
- **Driver registry is load-state only.** `DN_UDP`..`DN_SEAM` are names and
  toggles; there is no driver open/read/write/poll dispatch.
- **x86 NIC path is a probe.** Polled, single-flow, no IRQ, no ARP cache, not
  resident, not bound to NANNET `eth0`.
- **Full codec inventory is planned.** Only the codecs in section 8.2 are in
  the tree; the `TODO.md` user network spec is the larger target.

---

## 12. Source map

| Path | Contents |
|---|---|
| `src/nannet/nannet.nas` | control plane: links, addr, routes, DNS, WiFi, drivers, config |
| `src/nannet/overbootstrap_route.nas` | point -> page/address/route translation |
| `src/nannet/train_protocol.nas` | N16T frame build/validate/route/session |
| `src/nannet/n16t_android_abi.nas` | Android guest ABI + server handshake peer |
| `src/nannet/n16t_android_guest.nas` | Android protocol VM image |
| `src/nannet/n16t_server_test.nas` | server handshake/replay/CRC regression |
| `src/nannet/route_address.nas` | canonical `nan://...` parser |
| `src/nannet/object_key_decode.nas` | vector/hypergraph key decoder |
| `src/nannet/route_object_resolve.nas` | object registry owner/kind resolver |
| `src/nannet/n16_head_store.nas` | 255-head double-buffered bank |
| `src/nannet/n16_head_runtime.nas` | attach/read/observe runtime |
| `src/nannet/n16_head_worker.nas` | host-callable worker image |
| `src/nannet/runner_task.nas` | bounded runner task ledger |
| `src/nan/nannet_cart.nas` | NANNET service console |
| `src/nan/nic_cart.nas` | RTL8139 single-flow probe |
| `src/net/*.nas` | byte lanes, CRC32, FNV, hex/base64/base32, XOR, chunk, vector runner |
| `src/tests/net_test.nas` | codec/lane known-answer and vector tests |
| `src/nan/netcart.nas` | lane-engine self-check cart |
| `x86/net/ne2k_probe.nas` | NE2000 ARP probe |
| `aarch64/android/core/nan_net_driver.c` | fd framing + VM stage/extract |
| `aarch64/android/app/src/main/java/org/nan0s/vm/N16HttpsTransport.kt` | canonical HTTPS adapter |
| `.../N16RemoteSession.kt` | serialized remote exchange |
| `.../N16GuestProtocol.kt` | persistent guest + mailbox |
| `.../NaNNetTlsTransport.kt` | legacy `/n16t` adapter |
| `.../WifiBridge.kt` | Android WiFi host surface |
| `docs/NANNET_GLOBAL_ADDRESSING.md` | global mesh/transport authority |
| `aarch64/android/docs/N16T_GUEST_ABI.md` | Android N16T ABI |
| `src/nannet/README.md` | NANNET M1/M2/M3 notes |
| `x86/net/README.md` | x86 host-backed network notes |
| `TODO.md` | user network inventory (planned protocol fields/codecs) |

---

## Appendix A — N16T route-address examples

```text
nan://GM0:SC0:MC0:BS0:HW0::HW0:1::vector1337
nan://GM0:SC0:MC0:BS0:HW0::HW0:255::hypergraph42
```

Invalid examples:

```text
nan://GM0:SC0:MC0:BS0:HW0::HW0:0::vector1      # point 0 reserved
nan://GM0:SC0:MC0:BS0:HW0::HW0:256::vector1    # point 256 out of range
nan://GM0:SC0:MC0:BS0:HW0::HW0:1:vector1337    # missing '::'
nan://GM0:SC0:MC0:BS0:HW0::HW0:1::             # empty key
```

## Appendix B — N16T server handshake summary

```text
client HELLO (2 payload bytes, point 1)
  -> guest validate: magic/version/type/CRC/session/seq/length
  -> route point 1 -> 0xA001 -> NANNET route lookup
  -> server CAPABILITIES (8 payload bytes: point 1 + 6 zero)
  -> client validates response and advances session
client CLOSE (0 payload bytes)
  -> guest reset + terminal CLOSE reply
```

No training/merge capability bit is set in the current server peer.
