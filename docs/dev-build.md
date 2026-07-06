# Dev Build Variant

The Apple overlay branch carries a permanent Dev variant for downstream
experiments. Ordinary `SFI` builds remain the release-safe product and must use
a WLT-free `Libbox.xcframework`. The `SFI Dev` scheme uses the `Dev`
configuration, a `.dev` bundle identifier suffix, a separate app group, and the
`SFI_DEV` Swift compilation condition.

The ordinary libbox artifact is built or activated from:

```sh
LIBBOX_VARIANT=ordinary scripts/build_libbox.sh 1.13.13
scripts/verify_libbox_variant.sh ordinary build/libbox/ordinary/Libbox.xcframework
```

The Dev variant uses a separate cache path:

```sh
LIBBOX_VARIANT=dev scripts/build_libbox.sh 1.13.13
scripts/verify_libbox_variant.sh dev build/libbox/dev/Libbox.xcframework
```

Downstream branches may make Dev require WLT by setting
`SFI_REQUIRE_WLT_LIBBOX=YES` in the Dev build configuration or scheme
environment. Ordinary builds must not set `with_wlt`, and
`scripts/verify_libbox_variant.sh ordinary` rejects a WLT-enabled framework.
Each artifact records its exact core commit and variant in provenance manifests.
The Xcode project selects the ordinary path for Debug/Release and the separate
Dev path for Dev, so a missing artifact fails closed.
