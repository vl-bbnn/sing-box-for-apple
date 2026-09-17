import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class MemoryBudgetHostValidation(unittest.TestCase):
    def setUp(self):
        script = Path(__file__).resolve().parents[1] / "iphone_wlt_control.sh"
        source = script.read_text()
        self.validation = source.split(
            '/usr/bin/python3 - "$candidate_file" <<\'PY\'\n', 1
        )[1].split("\nPY\n", 1)[0]
        self.base = dict(max_active=56, max_open=16, dns_open_reserve=2,
                         max_pending=40, queue_timeout="2s", idle_timeout="30s",
                         peer_write_buffer=192, kcp_window=1024, kcp_buffer=2097152)

    def accepted(self, parameters):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "candidate.json"
            path.write_text(json.dumps({"parameters": parameters}))
            result = subprocess.run([sys.executable, "-", str(path)],
                                    input=self.validation, text=True,
                                    capture_output=True, timeout=5)
        return result.returncode == 0

    def test_optional_budget_and_mux_combinations(self):
        for mux in [False, True]:
            for limit in [None, 24, 32, 45]:
                with self.subTest(mux=mux, limit=limit):
                    parameters = dict(self.base)
                    if mux:
                        parameters.update(vless_mux_protocol="smux",
                                          vless_mux_max_connections=1,
                                          vless_mux_min_streams=4)
                    if limit is not None:
                        parameters["go_memory_limit_mib"] = limit
                    self.assertTrue(self.accepted(parameters))

    def test_invalid_budgets(self):
        for limit in [None, True, False, 23, 46, -1, "32", 32.5, {}, []]:
            with self.subTest(limit=limit):
                self.assertFalse(self.accepted(dict(self.base, go_memory_limit_mib=limit)))

    def test_budget_does_not_relax_mux_or_unknown_key_validation(self):
        for extra in [dict(unknown=1), dict(vless_mux_protocol="smux"),
                      dict(vless_mux_protocol="invalid", vless_mux_max_connections=1,
                           vless_mux_min_streams=4),
                      dict(vless_mux_protocol="smux", vless_mux_max_connections=True,
                           vless_mux_min_streams=4)]:
            with self.subTest(extra=extra):
                self.assertFalse(self.accepted(dict(self.base, go_memory_limit_mib=32, **extra)))


if __name__ == "__main__":
    unittest.main()
