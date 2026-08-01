# iPhone Whitelist Transport Test

Date: 2026-06-01

This checklist is for the first real iPhone test of the Turnable-backed
whitelist transport. Do not paste profile URLs, generated configs, cookies,
tokens, UUIDs, private IPs/domains, or production logs into public notes.

## Current Build State

- Server-side whitelist profile generation is already updated:
  - Core WLT service/outbound is emitted in the sing-box profile:
    `wlt-turnable`, `wlt-eu`, and `vless-wlt-eu.detour=wlt-eu`.
  - Turnable transport metadata is still emitted through the remote bootstrap
    endpoint for legacy sidecar fallback.
  - Turnable bootstrap now emits 1 peer by default for the iPhone gate.
  - Turnable bootstrap no longer sets `ignore_memory_limit=true`; iOS should
    keep sing-box's NetworkExtension memory guard enabled.
  - Turnable bootstrap is temporarily pruned to the `eu` route only for memory
    isolation; `ru/direct` selector testing is disabled in this mode.
  - VLESS whitelist outbounds support TCP+UDP with xudp.
  - non-DNS UDP routes to `whitelist-exit`.
  - YouTube domain suffixes route to `vless-wlt-eu`.
  - generated outbounds no longer use local WLT SOCKS/Turnable ports.
- In core WLT mode the packet tunnel must skip
  `LibboxStartWhitelistTransport`; sidecar mode is only a fallback for old
  profiles/lab.
- Turnable gateway is promoted to
  `0.4.1-2b2n-browser-pass-clean-20260531`.
- `Libbox.xcframework` was rebuilt from the local
  `/Users/operator/projects/sing-box-workspace/sing-box` working tree.
- The SFI Debug iOS app builds and passes codesign verification.
- The current diagnostics build adds packet-tunnel session IDs, startup timing,
  heartbeat, memory footprint, and iOS memory-pressure events to exported logs.
- The device helper clears stale `devicectl` outputs before install/launch.
- After the 2026-06-01 11:19/11:20/11:22 logs, the build also included
  the memory mitigation: iOS whitelist mode uses a smaller libbox log ring
  (`logMaxLines=300`), a lower libbox OOM limit (`44MiB`), throttled
  memory-pressure diagnostics, and a rebuilt sing-box core that no longer
  forwards filtered-out trace/debug logs into the iOS platform log buffer.
- The 2026-06-01 12:23/12:24 exports still self-disconnected. Those runs
  confirmed the resource policy reached iOS (`oomMemoryLimit=44MiB`), but the
  core OOM service still used the NetworkExtension default `50MiB` internally,
  so its threshold was too late for the observed iOS kill range.
- The latest local core build fixes that mismatch: NetworkExtension mode now
  honors `MemoryLimitOverride`, starts the adaptive OOM timer immediately, and
  clears the post-threshold cleanup flag correctly.
- `Libbox.xcframework` and the SFI Debug app were rebuilt after that fix.
- The 2026-06-01 14:36/14:38 exports still self-disconnected, but showed an
  important improvement: the core OOM guard now logs
  `memory threshold reached ... limit: 44 MB ... resetting network`.
  The remaining bug was that the adaptive timer stayed in `triggered` state and
  did not repeat reset/cleanup while memory rose again.
- The later core build adds a NetworkExtension-only retrigger cooldown:
  if memory remains above the trigger threshold, OOM reset/cleanup can repeat
  every 5 seconds instead of firing only once per tunnel session.
- `Libbox.xcframework` and the SFI Debug app were rebuilt after the retrigger
  fix. Install and launch both succeeded on the connected iPhone.
- The newest installed SFI build adds packet-tunnel memory recovery for
  whitelist transport. It restarts whitelist transport and reloads sing-box at
  about 42 MiB, and uses `mode=urgent` to bypass cooldown at about 44 MiB.

## Prepared Commands

Run from:

```sh
cd /Users/operator/projects/sing-box-workspace/sing-box-for-apple
```

Check sanitized device/build readiness:

```sh
scripts/iphone_whitelist_device.sh preflight
```

Rebuild only the iOS app into stable local DerivedData:

```sh
scripts/iphone_whitelist_device.sh build-app
```

After unlocking the iPhone and keeping the screen awake, install and launch:

```sh
scripts/iphone_whitelist_device.sh install
scripts/iphone_whitelist_device.sh launch
```

If `Libbox.xcframework` must be rebuilt again from local `sing-box`:

```sh
scripts/iphone_whitelist_device.sh rebuild-all
```

The script writes local diagnostic logs under:

```text
/Users/operator/projects/sing-box-workspace/sing-box-for-apple/build/
```

## Device Requirements

- iPhone connected to the Mac.
- iPhone unlocked during install.
- Trust this Mac accepted on the phone.
- Developer Mode enabled.
- Keep the screen awake until install and first launch finish.
- For the actual network test, disable Wi-Fi and use mobile data.

If a later install fails and preflight shows `tunnel=unavailable` or
`ddi=False`, unlock the phone, keep the screen awake, reconnect the cable if
needed, and rerun the install/launch commands above.

## App/Profile Steps

1. Launch SFI.
2. Import or select the existing remote profile whose URL points to the
   `-whitelist` config.
3. Refresh/update the remote profile after server-side route changes. This is
   required for the EU-only Turnable bootstrap value to reach the packet tunnel.
4. Start the VPN.
5. iOS should ask for VPN permission if this is a fresh install.
6. The packet tunnel should fetch the remote profile and then fetch the
   adjacent `/whitelist-transport` bootstrap metadata automatically.

The current server profile rejects UDP/443 before the generic UDP/xudp rule.
This is intentional for the iPhone gate: it forces QUIC/HTTP3 web traffic back
to TCP while keeping other UDP available for STUN/call diagnostics. The reject
uses `method=drop` so the tunnel does not answer every QUIC packet with ICMP
unreachable during startup.

The current whitelist profile is full-tunnel for user traffic in temporary
EU-only mode: DNS detours via `whitelist-exit`, `route.final` is
`whitelist-exit`, and the selector only leads to `vless-wlt-eu`. The only
`direct` route rule is the scoped VK-call/Turnable bootstrap exception; there
are no broad direct or direct IP-CIDR rules. If Yandex/WB call underlays are
added later, they should be added as equally scoped bootstrap exceptions, not as
generic direct routes.

FaceTime should also stay inside the WLT path. The current server profile does
not create a special FaceTime outbound: TCP follows `route.final`, and non-DNS
UDP follows the generic UDP rule, so both should show up under
`outbound/vless[vless-wlt-eu]`. If no FaceTime-related TCP/UDP activity appears
there, the traffic likely did not enter the packet tunnel.

The server profile no longer emits the deprecated `dns.independent_cache` flag.
If that warning still appears after refreshing the remote profile, the device is
using a cached config.

The exported SFI logs now append a persistent packet-tunnel section:

```text
=== packet-tunnel diagnostics ===
```

That section records packet tunnel lifecycle events even when the sing-box log
ends before the NetworkExtension stop reason appears.

For the current diagnostics build, every new tunnel attempt should include lines
like:

```text
(packet-tunnel): diagnostics session started ... [session=... uptime=...]
(packet-tunnel): startup stage=... elapsed=... total=... memory=...
(packet-tunnel): core whitelist transport detected; sidecar skipped
(packet-tunnel): sing-box service started elapsed=... memory=...
(packet-tunnel): heartbeat memory=... [session=... uptime=...]
```

If `whitelist transport started` appears with a refreshed core profile, the
device is still using an old sidecar config and should refresh the remote
profile before testing memory behavior.

If the VPN self-disconnects without a later
`diagnostics session ended reason=stopTunnel completed ...` line for the same
`session=...`, treat it as abrupt packet-tunnel process termination. The last
heartbeat/memory-pressure line is then the most important clue.

The 2026-05-31 23:38/23:39 iPhone exports showed the tunnel disappearing without
a final `stopTunnel(reason:)` entry. Treat the next test as a memory-limit
verification first: if the tunnel stays up longer after refresh, the likely
cause was iOS killing the extension while `ignore_memory_limit=true` was active.

The 2026-05-31 23:53 through 2026-06-01 00:11 exports improved, including one
default `ru` run that survived YouTube + Twitch, but still showed
`memory pressure: critical` / `OOM draft saved` around heavier navigation. The
server bootstrap was pruned again after those logs, first to two routes and
then to temporary EU-only mode.

The 2026-06-01 10:31/10:33/10:35 exports already used temporary EU-only
bootstrap (`listeners=eu`) and still self-disconnected. They did not include a
graceful `stopTunnel(reason:)` line, so the next run should prioritize the new
heartbeat and memory-pressure diagnostics over changing app log level.

The 2026-06-01 11:19/11:20/11:22 exports identified the current failure mode:
startup is about 3.1-3.7 seconds total, memory starts around 16 MiB after
sing-box starts, critical pressure begins around 40 MiB after 26-31 seconds,
and the last heartbeat is around 48-49.5 MiB before abrupt termination. The next
run should verify whether the installed mitigation keeps heartbeat memory below
the critical range or at least produces a `memory threshold reached`/network
reset instead of process death.

The 2026-06-01 12:23/12:24 exports showed the same abrupt termination with the
first mitigation installed. One default run had slow Turnable startup
(`whitelist transport` about 14.9 seconds) and died after the last heartbeat at
about 47 MiB. The trace run started normally (about 3.5 seconds total) and died
after the last heartbeat at about 49 MiB. Neither run had a graceful
`diagnostics session ended` line or a core `memory threshold reached` line.
This is why the next installed build changes the core OOM service itself.

The 2026-06-01 14:36/14:38 exports showed that the core OOM service fix reached
the device. One run stayed up much longer, about 296 seconds, before the last
heartbeat at about 47.9 MiB. The second run logged
`memory threshold reached ... resetting network` around 39 MiB, then later rose
again to about 48.4 MiB and disappeared. The next installed build should be
checked for repeated `memory threshold reached` lines if memory remains high.

The 2026-06-01 14:53 export was better for media: Twitch and YouTube worked for
several minutes, then Safari navigation drove the packet tunnel back to abrupt
termination. The latest session started in about 3.75 seconds, hovered around
38-41 MiB for most of the run, briefly reached about 44 MiB, dropped, and later
ended after the last heartbeat at about 48.3 MiB with no graceful
`diagnostics session ended` line. The exported sing-box ring only contained the
first few seconds of core logs, so the next build adds packet-tunnel-level
memory recovery that restarts whitelist transport and reloads sing-box when RSS
reaches about 42 MiB.

The 2026-06-01 15:11 export confirmed packet-tunnel memory recovery works:
several recoveries completed in about 1.1-1.4 seconds and dropped RSS back to
about 24-30 MiB. The final failure happened because recovery was skipped at
about 45.7 MiB with only about 5 seconds of cooldown remaining, then the last
heartbeat reached about 47.7 MiB before abrupt termination. The next installed
build shortens the normal recovery cooldown and adds an urgent mode that bypasses
cooldown at about 44 MiB.

For the next run, expected good evidence is either:

- heartbeat memory remains below the critical range during the manual smoke; or
- the exported log contains repeated
  `memory threshold reached ... resetting network` lines, followed by continued
  tunnel activity instead of PacketTunnel disappearance.
- the exported packet-tunnel diagnostics contain
  `memory recovery scheduled`, `memory recovery started`, and
  `memory recovery completed` lines, followed by continued tunnel activity
  instead of PacketTunnel disappearance.
- if memory reaches the dangerous range, `memory recovery scheduled mode=urgent`
  appears instead of a final cooldown skip.

Expected packet tunnel messages in SFI logs:

- `(packet-tunnel): Here I stand`
- `(packet-tunnel): starting whitelist transport transport=turnable`
- `(packet-tunnel): whitelist transport started`

If bootstrap fails, startup should fail before the tunnel starts because the
profile requires whitelist transport.

## Manual Smoke Matrix

Use mobile data for these checks:

- Open `stopgame.ru`.
- Open `rozetked.me`.
- Open `zol.ru`.
- Play the default YouTube mobile web video for at least 3 minutes.
- Play Twitch for at least 5 minutes.
- Run a basic DNS/UDP-sensitive app check.

Do not treat real calls as passed until they are tested separately. The lab
already passed UDP DNS/STUN, but that is only a prerequisite for calls.

## Failure Data To Collect

Keep logs sanitized. Useful lines are:

- SFI in-app log around tunnel startup.
- Packet tunnel messages containing `whitelist transport`.
- Any startup error from `WhitelistTransport`.
- Whether the exported sing-box log contains UDP/443 packet connections shortly
  before disconnect.
- Whether the SFI/system log has a NetworkExtension stop reason; the exported
  sing-box log may end before the actual packet-tunnel stop is recorded.
- The full `=== packet-tunnel diagnostics ===` section from the exported SFI
  logs after a disconnect.
- Whether the refreshed run contains any `memory pressure`, `OOM report`, or
  `memory threshold` lines.
- Whether the refreshed run contains any `memory recovery scheduled`,
  `memory recovery completed`, `memory recovery failed`, or
  `memory recovery skipped` packet-tunnel lines.
- Whether the failure was before VPN permission, during bootstrap, while
  starting Turnable, or after traffic started.

Avoid sharing raw generated configs, full bootstrap payloads, cookies, tokens,
private hostnames/IPs, or production logs.
