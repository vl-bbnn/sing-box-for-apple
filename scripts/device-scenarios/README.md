# iPhone Device Scenarios

`iphone_wlt_scenario.sh` runs an XCUITest scenario on one physical iPhone. The
runner accepts only a CoreDevice inventory entry whose transport is `wired`;
`DEVICE_ID` narrows that wired selection but cannot bypass it. The phone may use
cellular data exclusively because UI control travels over USB.

For an unattended repeatable cycle, use `iphone_wlt_cycle.sh`. It builds once,
reuses the same signed runner for subsequent iterations, and writes a compact
`cycle-status.tsv` next to per-run artifacts:

```sh
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

Before XCTest, the runner terminates stale `Runner.app` processes left on the
iPhone by earlier Xcode projects. It deliberately does not terminate the
device-side AutomationMode writer/UI processes: on current iOS/Xcode betas that
can discard an authenticated grant and cause a new passcode prompt. A retry
resets only stale runner processes and the current user's Mac CoreDevice
service. A surviving CoreDevice service
owned by another simultaneously logged-in macOS console user is reported as
`coredevice_competing_console_session`; log out that other console session and
rerun, because the current user cannot safely take over its automation channel.

For unattended cycles, configure the Mac once from an administrator session:

```sh
/usr/bin/automationmodetool enable-automationmode-without-authentication
```

This weakens the local Automation Mode authentication boundary until reverted
with `disable-automationmode-without-authentication`; use it only on a trusted
dedicated development Mac. The runner records `automation-mode-status.txt` and
stops with `automation_authorization_required` before XCTest when the one-time
setting is absent, avoiding an unattended stream of iPhone passcode prompts.

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

```sh
WLT_DEVICE_SCENARIO="$PWD/SFIUITests/wlt-network-cycle.json" \
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
- `WLT_SCENARIO_COREDEVICE_CLI` to override the selected `devicectl` executable;
- `WLT_SCENARIO_CLOSE_MIRRORING=1` only to close an already running Mirroring
  process before XCTest; the default is `0` and never interacts with it;
- `WLT_SCENARIO_PREFLIGHT_WAIT_SECONDS` (default `180`) to keep the command
  alive while waiting for one physical unlock or Wi-Fi trust refresh;
- `WLT_SCENARIO_INSTALL_APP=auto|always|never`; `auto` installs after a new
  build but reuses an installed app for `WLT_SCENARIO_SKIP_BUILD=1`, avoiding
  unnecessary developer-trust revalidation;
- `WLT_SCENARIO_PREFLIGHT_APP=0` only for diagnosing the preflight itself.

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
