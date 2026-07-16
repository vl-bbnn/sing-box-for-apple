# iPhone Device Scenarios

`iphone_wlt_scenario.sh` runs an XCUITest scenario on one physical iPhone. The
phone may use cellular data exclusively because UI control travels over USB.

The default scenario is `SFIUITests/wlt-mobile.json`. Override it without
editing the repository:

```sh
WLT_DEVICE_SCENARIO=/path/to/scenario.json scripts/iphone_wlt_scenario.sh
```

Coordinates are normalized to the active application's frame: `(0, 0)` is the
top-left corner and `(1, 1)` is the bottom-right corner. Supported actions are:

- `launch`, `activate`, `terminate`, and `home`;
- `tap`, `double_tap`, `long_press`, and `swipe`;
- `tap_element`, `tap_if_text`, `dismiss_pip`, `wait_element`, `assert_text`,
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
(`com.google.ios.youtube`), and Twitch (`tv.twitch`).

Keep private URLs and user-specific sequences outside the repository. The host
script injects the selected JSON into the UI-test runner through a generated
`.xctestrun` file and saves the scenario, XCTest result, screenshots, build log,
and the app-group `stderr`/WLT diagnostics under
`.local/wlt-test-artifacts/wlt-device-scenario-<timestamp>/` inside this
checkout. The `.local` tree is ignored by Git. Set
`WLT_TEST_ARTIFACT_ROOT` or `WLT_SCENARIO_ARTIFACT_DIR` to override it.
