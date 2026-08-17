# iPhone Device Scenarios

## Unattended headless WLT runner

### Unattended Wi-Fi/LTE transitions

The physical iPhone has three iCloud-synchronized Shortcuts prepared once while
an operator is present:

- `WLT LTE` only turns Wi-Fi off; it deliberately does not change the default
  voice line or cellular-data plan;
- `wltrescan` cycles Airplane Mode on, waits three seconds, cycles it off,
  waits eight seconds, invokes `WLT LTE`, and leaves Wi-Fi off;
- `WLT WiFi` turns Wi-Fi on.

Dual-SIM acceptance additionally uses `WLT Switch SIM`. Its contract is narrow:
it changes only the cellular-data line between the two already enabled plans,
leaves `Default Voice Line` unchanged, and never changes either plan's On/Off
state. The active shortcut has been verified in Cellular Settings in both
directions. Archived shortcuts whose names contain `enables plans` or
`Recover Voice` are not test controls and must not be invoked.

`iphone_network_transition.sh` starts these shortcuts with CoreDevice's
`--payload-url`, without XCTest or Automation Mode. It then launches the
already-installed Dev app only in its cleanup/network-snapshot mode and accepts
the transition from the resulting `NWPath`: LTE requires
`wifi=false cellular=true` plus LTE/5G radio technology, while Wi-Fi recovery
requires `wifi=true cellular=false`. A failed LTE transition restores Wi-Fi by
default and is an infrastructure/precondition failure.

Never run these synchronized Shortcuts with the macOS `shortcuts run` command
or the Play button in the Mac Shortcuts app. Network actions execute in the
environment that launches them; a Mac launch can disable the Mac's own Wi-Fi
and take the whole test host offline. The harness always launches
`com.apple.shortcuts` on the explicit physical-iPhone UDID through CoreDevice.

The ordinary `WLT LTE` path does not reset a healthy radio registration. If the
strict cellular snapshot reports EDGE/3G or any other non-LTE/5G technology,
the runner invokes `wltrescan` and repeats the in-app proof. It allows two
rescans by default; `WLT_TRANSITION_LTE_RESCAN_ATTEMPTS` and
`WLT_TRANSITION_LTE_RESCAN_WAIT_SECONDS` are diagnostic overrides. A run that
still cannot prove LTE/5G remains a precondition failure and is never counted
as WLT transport quality.

`WLT_TRANSITION_FORCE_LTE_RESCAN=1` exists only to qualify the rescan branch
while the phone already has LTE/5G. Normal comparison runs leave it unset and
cycle Airplane Mode only after a proven non-LTE cellular snapshot.

Do not invoke an older cellular-line repair shortcut from ordinary unattended
Wi-Fi/LTE transitions. Changing the default voice/data line can present iOS's blocking
`Default Settings Changed` acknowledgement. That modal prevents later
deep-linked Shortcuts such as Wi-Fi restoration from running. Line selection is
a supervised provisioning operation; normal transitions and radio rescans stay
on the already selected data line.

`iphone_wlt_dual_sim.sh` is the supervised dual-SIM matrix wrapper. It launches
`WLT Switch SIM` through CoreDevice on the physical iPhone (never with macOS
`shortcuts run`), captures Cellular Settings before and after the change, runs
the same headless LTE scenario on each data line, and uses an EXIT trap to
restore the original data line even when either scenario fails. Each headless
phase independently stops VPN and restores Wi-Fi. Review the three
`cellular-*.png` files to confirm that both plans stayed `On` and the voice line
did not change.

```sh
DEVICE_ID=<physical-iphone-udid> \
WLT_DUAL_SIM_CONFIGURATION=scripts/device-scenarios/wlt-headless-lte-ru-sites-1mib.json \
  scripts/iphone_wlt_dual_sim.sh
```

```sh
DEVICE_ID=<physical-iphone-udid> scripts/iphone_network_transition.sh lte
# run LTE transport acceptance
DEVICE_ID=<physical-iphone-udid> scripts/iphone_network_transition.sh wifi
```

Build/install/trust remains forbidden on LTE. Run `wifi` and obtain a fresh
unrestricted-Wi-Fi proof before any provisioning operation.

Provisioning keeps the default strict Wi-Fi rule (`wifi=true cellular=false`).
The comparison runner may accept a mixed Wi-Fi Assist NWPath only with
`WLT_TRANSITION_ALLOW_MIXED_WIFI=1`; in that mode the Dev app sets
`URLSessionConfiguration.allowsCellularAccess=false` for every baseline page,
resource, and warm probe and records `cellular_access_allowed=false` in the
result. This prevents a Wi-Fi baseline request from silently switching egress
to cellular while preserving the strict provisioning/trust gate.

### Normalized Wi-Fi / native LTE / WLT comparison

`iphone_wlt_comparison.sh` runs a two-phase matrix:

1. unrestricted Wi-Fi without VPN runs the complete content/resource/playback
   matrix;
2. LTE with WLT runs the same complete HTTP/content/resource matrix as Wi-Fi.

Native LTE without VPN is intentionally not run in the restricted-network
acceptance cycle: nearly all useful controls can be blocked by policy, so their
timeout is not a radio-speed measurement. `comparison.json` records that phase
as `not_applicable_restricted_lte`. WLT/Wi-Fi timing remains descriptive because
it includes the normal Wi-Fi/LTE radio difference; functional success, content
similarity, and resource completeness are the acceptance gates.

YouTube and Twitch playback are intentionally excluded from the headless
WebKit verdict. YouTube embeds can return anti-bot/referrer error 152 even when
connectivity and CDN requests pass, and a fixed Twitch live channel can be
offline. Playback acceptance therefore uses the native iOS apps: YouTube search
to a selected 1080p60/720p60 stream with at least 30 seconds of position advance,
and Twitch selection of an actually available live/VOD with motion/quality
checks. The native app media gate runs on unrestricted Wi-Fi and LTE+WLT, never
on restricted native LTE without VPN.

The Dev runner records timing plus privacy-preserving content fingerprints:
raw-body SHA-256, normalized text-token hashes, normalized resource-manifest
hashes, byte counts, and resource success percentage. Raw page bodies are not
retained. `summarize_wlt_comparison.py` writes `comparison.json` and
`comparison.md`. Restricted functional probes compare Wi-Fi directly with
LTE+WLT for success, content, and resource completeness. Content similarity
uses a 0.75 Wi-Fi/WLT floor, with a wider 0.65 allowance for EU routes.

```sh
DEVICE_ID=<physical-iphone-udid> \
WLT_COMPARISON_ARTIFACT_DIR=/path/to/checkpoint/comparison-r1 \
scripts/iphone_wlt_comparison.sh
```

The runner restores stopped VPN plus Wi-Fi in its exit trap. Final cleanup may
accept a mixed Wi-Fi Assist path (`wifi=true cellular=true`) because cellular
service and both SIM lines must remain enabled; this exception does not apply
to the strict unrestricted-Wi-Fi gate before provisioning or remote-profile
refresh. The Dev app
temporarily disables the iOS idle timer while a headless phase is active and
restores the previous setting afterward, preventing long playback matrices from
auto-locking before cleanup. A physical lock at host transition time or a failed
LTE transition remains infrastructure and prevents comparison rather than
producing misleading transport scores.

If a host timeout occurs, `iphone_wlt_headless.sh` preserves the last app-side
state as `partial-result.json` before launching cleanup and writes the cleanup
state separately as `cleanup-result.json`; cleanup no longer overwrites the
partial diagnostic evidence.

Regular overnight WLT transport acceptance must not depend on XCUITest or
device-side Automation Mode. The Dev app contains an opt-in headless runner
that is launched through CoreDevice, controls its own `NEVPNManager`, verifies
the active `NWPath` and LTE/5G radio technology, switches the WLT RU/EU selector,
runs HTTP/resource and WebKit playback probes, and writes a compact JSON result
to the shared app-group cache. The host runner only launches an already
installed app and copies evidence; it never builds, installs, refreshes the
profile, enters a passcode, or enables UI Automation:

```sh
DEVICE_ID=<physical-iphone-udid> \
WLT_HEADLESS_ARTIFACT_DIR=/path/to/checkpoint/ios/headless-r1 \
scripts/iphone_wlt_headless.sh
```

The default scenario requires `wifi=false cellular=true` plus LTE/5G before
starting WLT and rechecks the same condition after final cleanup. The host
runner prepares that initial path itself: it invokes the device-side Wi-Fi or
LTE Shortcut before launching the scenario, and the LTE transition performs
an airplane-mode rescan only after an in-app snapshot proves EDGE/3G. Offline,
locked, missing-app, exhausted-rescan, and cleanup failures remain
infrastructure rather than transport quality. Set
`WLT_HEADLESS_PREPARE_TRANSPORT=0` only for a diagnostic run that has already
proved the required path atomically. One supervised unrestricted-Wi-Fi setup is
still required whenever a new signed Dev binary must be installed or trusted.
Repeated runs of that installed binary require no XCTest permission and no
user confirmation.

`wlt-headless-soak.json` keeps one PacketTunnel/WLT session active for at
least 30 minutes. `soak_duration_seconds`, `soak_interval_seconds`, and
`soak_probe` schedule an immediate probe and periodic probes without stopping
the VPN between them. The result records `soak_elapsed_ms` and `soak_samples`
inside the repetition, so a short host run cannot be mistaken for endurance
evidence. Soak cannot be combined with network-recovery phases; recovery uses
its own LTE→Wi-Fi→LTE scenario and transport checkpoints.

XCUITest remains useful as a separate, explicitly supervised native-app UX
gate for accessibility navigation and screenshots. It is not a prerequisite
for unattended WLT transport qualification. `iphone_wlt_scenario.sh` therefore
refuses to create a UI-automation session by default. An operator who is
physically present must opt in with
`WLT_SCENARIO_UI_AUTHORIZATION=supervised`; recurring jobs must never set that
variable.

This is the cross-project policy for physical iPhones:

- build, install, developer trust, and profile refresh are a separate
  supervised provisioning phase on unrestricted Wi-Fi;
- recurring transport, protocol, API, database, and media checks run inside an
  already installed signed app and are launched with `devicectl`, not XCTest;
- native UI navigation and screenshots are a supervised acceptance gate, not a
  nightly prerequisite;
- a locked phone, wrong network, EDGE, missing binary, or expired signature is
  an infrastructure/precondition failure and must never be scored as product
  quality;
- stock iOS provides no supported way to pre-authorize arbitrary XCUITest UI
  sessions forever. A reboot, beta update, runner replacement, or device policy
  may show the device-passcode sheet again; the harness must stop rather than
  request, store, or bypass that passcode.

`iphone_wlt_scenario.sh` runs an XCUITest scenario on one physical iPhone. The
runner accepts only a CoreDevice inventory entry whose transport is `wired`;
`DEVICE_ID` narrows that wired selection but cannot bypass it. The phone may use
cellular data exclusively because UI control travels over USB.

For an unattended repeatable cycle, use `iphone_wlt_cycle.sh`. It builds once,
reuses the same signed runner for subsequent iterations, and writes a compact
`cycle-status.tsv` next to per-run artifacts:

```sh
WLT_SCENARIO_UI_AUTHORIZATION=supervised \
WLT_CYCLE_RUNS=2 scripts/iphone_wlt_cycle.sh
```

The host runner does not start, control, or depend on iPhone Mirroring. It
validates the scenario, repairs known CoreDevice initialization races, installs
the signed app, and launches it before the test. When a newer compatible
CoreDevice framework is installed globally next to an older Xcode, the runner
uses that framework's `devicectl` directly instead of the Xcode wrapper: the
wrapper can otherwise invoke `xcodebuild -runFirstLaunch` repeatedly because
its hardcoded version no longer matches. This preflight classifies a secure
lock, missing developer trust, and disabled Developer Mode before Wi-Fi is
disabled. Physical passcode/Face ID unlock remains intentionally impossible to
automate.

Developer trust must be established by launching the built runner while the
unlocked iPhone has unrestricted Wi-Fi access to Apple's verification
services. On affected iOS/Xcode versions, **Settings -> General -> VPN & Device
Management** may contain no developer entry even though XCTest reports
`Developer App Certificate is not trusted`; there is then no manual trust
button to press. Return the device to Wi-Fi and rerun the no-op XCTest
preflight. Do not rebuild or reinstall on restricted LTE: validation cannot
complete there, and either action can invalidate a runner that was already
usable. After one successful Wi-Fi launch, reuse the same build with
`WLT_SCENARIO_SKIP_BUILD=1` and `WLT_SCENARIO_INSTALL_APP=never` for LTE cycles.

Before XCTest, the harness preserves existing `Runner.app` processes by
default. Current iOS/Xcode betas can bind the device-side Automation Mode grant
to that process, so eagerly terminating it may cause a fresh iPhone passcode
prompt even when `automationmodetool status` says the Mac does not require
authentication. A runner is cleared only after a proven XCTest session
failure; `WLT_SCENARIO_RESET_RUNNERS_BEFORE_TEST=1` exists solely as an explicit
diagnostic escape hatch. The harness never terminates the device-side
AutomationMode writer.
`WLT_SCENARIO_RESET_AUTOMATION_ON_TIMEOUT=1` is therefore rejected as unsafe.
On an Automation Mode timeout the runner captures the device lock state and a
screenshot, identifies a visible passcode sheet, and stops without retrying.
Other transient CoreDevice failures may reset only stale runners and the
current user's Mac CoreDevice service before retrying. A surviving CoreDevice
service owned by another simultaneously logged-in macOS console user is reported as
`coredevice_competing_console_session`; log out that other console session and
rerun, because the current user cannot safely take over its automation channel.
A second logged-in session without its own live CoreDevice service is recorded
for diagnostics but is not classified as competition.

For supervised XCUITest sessions, configure the dedicated Mac once from an
administrator session:

```sh
/usr/bin/automationmodetool enable-automationmode-without-authentication
```

This weakens only the Mac's local Automation Mode authentication boundary until reverted
with `disable-automationmode-without-authentication`; use it only on a trusted
dedicated development Mac. It does **not** authorize the separate iPhone
passcode sheet seen on current iOS betas. The runner records
`automation-mode-status.txt` and stops before XCTest when the Mac setting is
absent.

The default scenario is `SFIUITests/wlt-mobile.json`. Override it without
editing the repository:

```sh
WLT_DEVICE_SCENARIO=/path/to/scenario.json scripts/iphone_wlt_scenario.sh
```

Use `SFIUITests/wlt-network-cycle.json` for the shorter infrastructure gate.
It verifies that the already-installed and trusted Dev build can refresh its
profile on Wi-Fi, disable the Wi-Fi radio in Settings over the wired XCTest
channel, start WLT on LTE, load a real Safari page, and restore Wi-Fi through
the same Settings path during teardown. It does not use iPhone Mirroring or
Control Center for network switching. Run it twice with the same build before
treating Wi-Fi/LTE switching and developer-trust reuse as unattended:

The network gate is strict: before LTE traffic, `NWPath` must report
`wifi=false cellular=true`; after teardown, it must report
`wifi=true cellular=false`. A merely satisfied non-Wi-Fi path is not accepted
as proof of cellular service.

```sh
WLT_DEVICE_SCENARIO="$PWD/SFIUITests/wlt-network-cycle.json" \
WLT_SCENARIO_UI_AUTHORIZATION=supervised \
WLT_SCENARIO_SKIP_BUILD=1 \
WLT_SCENARIO_INSTALL_APP=never \
WLT_CYCLE_RUNS=2 \
scripts/iphone_wlt_cycle.sh
```

Use `SFIUITests/wlt-memory-cycle.json` for the bounded RU -> EU -> RU endurance
gate. It runs six 8 MiB downloads and holds the tunnel between route changes so
PacketTunnel RSS, memory pressure, thermal state, and normal shutdown can be
compared across repeated runs:

```sh
WLT_DEVICE_SCENARIO="$PWD/SFIUITests/wlt-memory-cycle.json" \
WLT_SCENARIO_UI_AUTHORIZATION=supervised \
WLT_SCENARIO_SKIP_BUILD=1 \
WLT_SCENARIO_INSTALL_APP=never \
WLT_CYCLE_RUNS=3 \
scripts/iphone_wlt_cycle.sh
```

When more than one Apple development team is available, select the team used
to sign both the app and the UI-test runner explicitly:

```sh
WLT_SCENARIO_DEVELOPMENT_TEAM=YOUR_TEAM_ID scripts/iphone_wlt_scenario.sh
```

Useful cycle controls are:

- `WLT_TEST_ARTIFACT_ROOT` to move all default scenario and cycle artifacts;
- `WLT_CYCLE_RUNS` and `WLT_CYCLE_PAUSE_SECONDS`;
- `WLT_CYCLE_CONTINUE_ON_FAILURE=1` to retain independent repeated evidence;
- `WLT_SCENARIO_SKIP_BUILD=1` to reuse an existing DerivedData build from the
  first run;
- `WLT_SCENARIO_COREDEVICE_RETRIES` for local CoreDevice recovery attempts;
- `WLT_SCENARIO_TEST_ATTEMPTS` may retry ordinary transient XCTest/CoreDevice
  startup failures. An Automation Mode timeout is never retried automatically,
  because current iOS betas can present a device-passcode sheet and an
  identical retry only creates another authorization request. The runner
  captures that screen and uses on-host Vision OCR to report the specific
  `automation_authorization_required` infrastructure classification without
  reading, requesting, or storing the passcode;
- `WLT_SCENARIO_COREDEVICE_CLI` to override the selected `devicectl` executable;
- `WLT_SCENARIO_CLOSE_MIRRORING=1` only to close an already running Mirroring
  process before XCTest; the default is `0` and never interacts with it;
- `WLT_SCENARIO_PREFLIGHT_WAIT_SECONDS` (default `180`) to keep the command
  alive while waiting for one physical unlock or Wi-Fi trust refresh;
- `WLT_SCENARIO_INSTALL_APP=auto|always|never`; `auto` installs after a new
  build but reuses an installed app for `WLT_SCENARIO_SKIP_BUILD=1`, avoiding
  unnecessary developer-trust revalidation;
- `WLT_SCENARIO_REPETITIONS=3` repeats the complete scenario inside one
  `xcodebuild`/XCTest session. Metric names and failure sections receive an
  `r01-`/`r02-`/`r03-` prefix, and the declared cleanup runs as a fatal state
  boundary between repetitions. This is the preferred unattended iOS mode:
  current iOS betas can request the device passcode again whenever a new UI
  automation session is created, while one long-lived session needs at most
  the single authorization shown at its start;
- `WLT_SCENARIO_TARGET_APP=/absolute/path/to/dev-vpn.app` to make the
  xctestrun use a separately built, explicitly selected target application.
  This is required when reusing an older UI-test DerivedData directory with a
  newer Network Extension build: `xcodebuild test-without-building` may install
  `UITargetAppPath` independently of `WLT_SCENARIO_INSTALL_APP=never`;
- `WLT_SCENARIO_PREFLIGHT_APP=0` only for diagnosing the preflight itself.

`WLT_DEVICE_AUTOSTART=1` now uses the already stored profile without a remote
update. Set `WLT_DEVICE_AUTOSTART_REFRESH_PROFILE=1` only for an explicit
refresh comparator on unrestricted Wi-Fi; it must never be used as a warm-up
step for a no-refresh LTE acceptance run.

When a scenario reaches PacketTunnel but WLT cannot start, the host result is
refined to `wlt_auth_required` or `wlt_carrier_connect_failed` when the latest
diagnostic session contains the corresponding sanitized failure. These are
actionable WLT results, not trust or CoreDevice failures.

Coordinates are normalized to the active application's frame: `(0, 0)` is the
top-left corner and `(1, 1)` is the bottom-right corner. Supported actions are:

- `launch`, `activate`, `terminate`, `home`, `disable_wifi`, and `enable_wifi`;
- `tap`, `double_tap`, `long_press`, and `swipe`;
- `tap_element`, `tap_any`, `tap_if_any`, `tap_if_text`, `tap_if_text_at`,
  `dismiss_pip`, `wait_element`, `wait_any`, `assert_text`,
  `assert_text_contains`, `assert_connection_status`, `assert_text_absent`, and
  `assert_any_absent`;
- `type`, `type_into`, `type_into_any`, `wait`, `screenshot`, and `dump_ui`;
- `select_outbound`, `youtube_quality`, `tap_twitch_live`, `tap_twitch_vod`, `twitch_quality`, `testflight_install`,
  `measure_download`,
  `assert_value_changes`, and `tap_and_assert_selected`;
- `open_telegram_saved_messages` and `open_whatsapp_self_chat`.

`type_into` focuses the element identified by `identifier` or `label` before
typing. `tap_if_text` taps its target only when the supplied static `text` is
currently visible, which is useful for normalizing state at scenario start.
`enable_wifi` succeeds only after `NWPathMonitor` confirms that Wi-Fi is the
active traffic path; the Settings switch alone is not accepted as proof of
connectivity.
`assert_connection_status` reads the dedicated connection-status accessibility
node and waits for an exact state. While the runner sets `WLT_DEVICE_SCENARIO`,
the Dev app also exposes transparent 44-point
`wlt.scenario.connection.start`/`stop` controls. They avoid the iOS 26+
SwiftUI tab-bar accessory bug where a visible start button can report
`isHittable=false`; ordinary Dev launches and all non-Dev builds omit them.
`dismiss_pip` uses the SpringBoard accessibility hierarchy to close an active
Picture-in-Picture window without relying on localized button labels or screen
coordinates.

Element actions accept singular `identifier`, `label`, and `contains_text`, or
their plural `identifiers`, `labels`, and `contains_texts` variants. Use
`element_type` / `element_types` for controls that expose only their XCTest
type (`text_view`, `text_field`, `search_field`, `button`, or `cell`). The
runner prefers a hittable match over hidden duplicate controls.

`assert_app_ready` can distinguish explicit errors, authentication screens,
and stalled loading with `failure_texts`, `auth_texts`, `loading_texts`, and
`loading_identifiers`. A visible loading marker takes precedence over a success
marker until the loading marker disappears.

To test an actual TestFlight reinstall, declare removable bundle identifiers in
the scenario's host preflight and then install the matching card by its visible
TestFlight name:

```json
{
  "host_preflight": {
    "uninstall_apps": ["com.example.app.dev"]
  },
  "steps": [
    {
      "action": "testflight_install",
      "app": "testflight",
      "text": "Example App",
      "timeout": 180,
      "fatal": true
    }
  ]
}
```

The host uninstall runs only after the signed VPN app passes its launch/trust
preflight. `testflight_install` scopes `Install`/`Update` and `Open` to the row
whose visible app title matches `text`, so unrelated TestFlight cards cannot
satisfy the step. Launch the installed bundle in a following scenario step to
prove that installation completed.

`measure_download` performs an uncached HTTPS download from the UI-test process,
which traverses the active system VPN on the physical iPhone. Put the absolute
URL in `text`; `minimum_bytes` verifies completeness and the optional
`minimum_bytes_per_second` turns the measurement into a throughput gate. The
result attachment records host, HTTP status, bytes, elapsed time, B/s, and
KiB/s without storing the URL path or query.

Use `range_bytes` with a static server that advertises `Accept-Ranges: bytes`
when the public origin does not provide a stable exact-size URL. The runner
requests `bytes=0-(range_bytes-1)` and still validates the received size through
`minimum_bytes`.

Set `continue_on_failure` on the scenario to keep independent application
checks running after a failure. Mark infrastructure steps with `fatal: true`.
`disable_wifi` first normalizes the Wi-Fi radio in Settings and then disconnects
only the current access point through Control Center. Cellular data becomes the
traffic path, while the radio stays enabled for Continuity and recovery.
Teardown reconnects Wi-Fi first, then runs `cleanup_steps`, then performs the
generic VPN stop. WLT scenarios that select EU should restore
`whitelist-exit` to `ru` in `cleanup_steps`.

The default scenario covers RU sites and applications, YouTube 1080p60 or
720p60 HDR playback, Twitch live and VOD at 720p60, then EU sites and social
feeds. Communication checks are intentionally separate because they send a
marker or join voice. Keep the operator-specific scenario under an ignored
local path and run it explicitly:

`youtube_quality` first navigates to YouTube's fixed-resolution list and only
then selects a preferred row. When YouTube omits accessibility labels, the
runner probes settings rows but requires at least five full-width resolution
rows before accepting the sheet. A `1.00x` playback-speed sheet is explicitly
rejected, and a coordinate tap without validated resolution-list geometry is
never accepted as quality evidence.

```sh
WLT_DEVICE_SCENARIO=/path/to/wlt-mobile-communication.json \
  scripts/iphone_wlt_scenario.sh
```

Application aliases are declared in the scenario's `apps` dictionary. `vpn`
is reserved for the SFI application under test. Known public bundle IDs used by
the default scenario are Safari (`com.apple.mobilesafari`), YouTube
(`com.google.ios.youtube`), and Twitch (`tv.twitch`).

Keep private URLs and user-specific sequences outside the repository. The host
script injects the selected JSON into the UI-test runner through a generated
`.xctestrun` file and saves the scenario, XCTest result, screenshots, build log,
and the app-group `stderr`/WLT diagnostics under
`.local/wlt-test-artifacts/wlt-device-scenario-<timestamp>/` inside this
checkout. The `.local` tree is ignored by Git. Set `WLT_TEST_ARTIFACT_ROOT` or
the existing per-run `WLT_SCENARIO_ARTIFACT_DIR` / `WLT_CYCLE_ARTIFACT_DIR`
overrides when a different destination is required.

When the VPN app is launched by the scenario runner, it also snapshots the
extension command log to `wlt-device-service.log` on foreground activation.
This preserves WLT stream, mux, queue, throughput, and reconnect counters for
post-run comparisons without changing normal app behavior.
