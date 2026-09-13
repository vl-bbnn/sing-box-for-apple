# Host injected radio loss verdict v2

The current runner classifies samples relative to requested `loss_after_seconds`, not measured shortcut invocation. It also credits the first later success and does not reject failures after recovery; when `unplanned_soak_failures` is absent, the final check treats the run as clean. This directory contains a host-only successor prototype.

`classify_injected_recovery_v2.py` accepts measured `--injection-start-ms` and `--injection-end-ms`, preserves the input JSON unchanged, requires a pre-injection success, requires the first failure no earlier than the injection window (allowing 7.5 s scheduler timestamp tolerance) and no later than injection end + 90 s, requires success within 90 s, and rejects any later failure. No loss observed is infrastructure (exit 2); malformed sequence or late/extra failures are failed (exit 1).

At a 900 s / 15 s / 180 s requested run, this means the configured 180 s offset is only a wakeup target. The runner should timestamp immediately before and after `wltrescan`; the classifier should use that measured interval. Existing `soak_probe_samples` are retained verbatim and a separate verdict is stored.
