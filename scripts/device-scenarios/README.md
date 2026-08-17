# iPhone Device Scenarios

`iphone_wlt_scenario.sh` runs an XCUITest scenario on one physical iPhone. The
phone may use cellular data exclusively because UI control travels over USB.

The default scenario is `SFIUITests/wlt-mobile.json`. Override it without
editing the repository:

```sh
WLT_DEVICE_SCENARIO=/path/to/scenario.json scripts/iphone_wlt_scenario.sh
```

For repeated measurements against an app and UI-test runner that are already
installed by a previous run, preserve the app container and skip installation:

```sh
WLT_SCENARIO_USE_DESTINATION_ARTIFACTS=1 \
WLT_SCENARIO_SKIP_BUILD=1 \
WLT_SCENARIO_BUILD_DIR=/path/to/existing/DerivedData \
scripts/iphone_wlt_scenario.sh
```

Destination-artifacts mode fails early when either bundle is not installed.
The script also refuses to start while another `xcodebuild` references the same
iPhone by CoreDevice identifier or UDID. Do not bypass that preflight unless
the overlap is intentional. If Xcode requests UI Automation permission, keep
the phone unlocked and enter its passcode; do not terminate the automation-mode
helper, because doing so resets the authorization.

Coordinates are normalized to the active application's frame: `(0, 0)` is the
top-left corner and `(1, 1)` is the bottom-right corner. Supported actions are:

- `launch`, `launch_if_installed`, `activate`, `terminate`, and `home`;
- `tap`, `double_tap`, `long_press`, and `swipe`;
- `tap_element`, `tap_if_text`, `tap_text`, `tap_text_if_present`, `dismiss_pip`,
  `wait_element`, `wait_text`, `wait_text_absent`, `wait_text_if_present`, `assert_text`,
  and `assert_text_absent`;
- `type`, `type_into`, `wait`, `screenshot`, and `dump_ui`.

`type_into` focuses the element identified by `identifier` or `label` before
typing. `tap_if_text` taps its target only when the supplied static `text` is
currently visible, which is useful for normalizing state at scenario start.
`dismiss_pip` uses the SpringBoard accessibility hierarchy to close an active
Picture-in-Picture window without relying on localized button labels or screen
coordinates.

Application aliases are declared in the scenario's `apps` dictionary. `vpn`
is reserved for the SFI application under test. Known public bundle IDs used by
the default scenario are Safari (`com.apple.mobilesafari`), YouTube
(`com.google.ios.youtube`), Twitch (`tv.twitch`), and Discord
(`com.hammerandchisel.discord`).

Keep private URLs and user-specific sequences outside the repository. The host
script injects the selected JSON into the UI-test runner through a generated
`.xctestrun` file and saves the scenario, XCTest result, screenshots, build log,
and the app-group `stderr`/WLT diagnostics under
`.local/wlt-test-artifacts/wlt-device-scenario-<timestamp>/` inside this
checkout. The `.local` tree is ignored by Git. Set
`WLT_TEST_ARTIFACT_ROOT` or `WLT_SCENARIO_ARTIFACT_DIR` to override it.
