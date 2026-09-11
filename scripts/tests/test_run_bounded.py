import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


HELPER = Path(__file__).parents[1] / "run_bounded.py"


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def wait_for_file(path: Path) -> None:
    deadline = time.monotonic() + 3
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    if not path.exists():
        raise AssertionError(f"timed out waiting for {path}")


def wait_gone(pid: int) -> None:
    deadline = time.monotonic() + 3
    while process_exists(pid) and time.monotonic() < deadline:
        time.sleep(0.02)
    if process_exists(pid):
        raise AssertionError(f"process {pid} survived")


class RunBoundedTests(unittest.TestCase):
    def test_timeout_kills_grandchild_that_ignores_term(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "grandchild.pid"
            program = (
                "import pathlib,signal,subprocess,sys,time;"
                "p=subprocess.Popen([sys.executable,'-c',"
                "'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)']);"
                "pathlib.Path(sys.argv[1]).write_text(str(p.pid));time.sleep(60)"
            )
            result = subprocess.run(
                [sys.executable, str(HELPER), "0.2", "--", sys.executable, "-c", program, str(pid_file)],
                timeout=5,
            )
            self.assertEqual(result.returncode, 124)
            wait_for_file(pid_file)
            wait_gone(int(pid_file.read_text()))

    def test_signal_is_forwarded_and_cleans_grandchild(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "grandchild.pid"
            program = (
                "import pathlib,subprocess,sys,time;"
                "p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']);"
                "pathlib.Path(sys.argv[1]).write_text(str(p.pid));time.sleep(60)"
            )
            supervisor = subprocess.Popen(
                [sys.executable, str(HELPER), "60", "--", sys.executable, "-c", program, str(pid_file)]
            )
            wait_for_file(pid_file)
            supervisor.send_signal(signal.SIGTERM)
            self.assertEqual(supervisor.wait(timeout=5), 128 + signal.SIGTERM)
            wait_gone(int(pid_file.read_text()))

    def test_timeout_preserves_unrelated_process(self) -> None:
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            result = subprocess.run(
                [sys.executable, str(HELPER), "0.1", "--", sys.executable, "-c", "import time; time.sleep(60)"],
                timeout=5,
            )
            self.assertEqual(result.returncode, 124)
            self.assertIsNone(unrelated.poll())
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
