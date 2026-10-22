# WLT Apple source checkpoint — 2026-10-22

This branch preserves the 361 public frontend source files used by the prepared
1.13.13 / 2026101901 signed candidate. The source hashes are in
`WLT-SOURCE-CHECKPOINT.json`. It was built with core
`24f981726a87eb9dc08cd9a526e33111528193d3` and was not installed or qualified
on a physical iPhone. It is separate from the installed Android checkpoint.

The private signing/identity override `Config/Overlay.local.xcconfig` is excluded.
Runestone remains a submodule pinned to
`baeb3cbf8332d26b4f7b4c175a01f288ebbf3e7f`; all 527 retained dependency files
were checked against that revision. Base-only files and licenses are retained.
Executable bits lost in the source-only export were recovered for 18 scripts;
the manifest records these paths. No retained source bytes were changed.

Host checks: 49 of 50 pass after mode recovery. The retained stability test
expects `probeTraffic(timeout: 12)` while the retained candidate source uses
`firstTrafficProbeTimeout` (60 seconds). Both are preserved for review; this
checkpoint does not resolve or waive that failure. No fresh app build or device
run was performed from this reconstructed Git tree. Do not promote it as a
qualified release. The signed artifact and its original private source map remain
in the separate verified recovery kit.
