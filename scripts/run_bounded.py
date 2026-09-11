#!/usr/bin/env python3
"""Run one command in a private process group with a host-side deadline."""

from __future__ import annotations

import argparse
import errno
import os
import signal
import subprocess
import sys
import time


TERMINATION_GRACE_SECONDS = 1.0


def signal_group(process_group: int, signal_number: int) -> None:
    try:
        os.killpg(process_group, signal_number)
    except (ProcessLookupError, PermissionError):
        pass


def group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def stop_group(process_group: int) -> None:
    signal_group(process_group, signal.SIGTERM)
    deadline = time.monotonic() + TERMINATION_GRACE_SECONDS
    while group_exists(process_group) and time.monotonic() < deadline:
        time.sleep(0.02)
    if group_exists(process_group):
        signal_group(process_group, signal.SIGKILL)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("seconds", type=float)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.seconds <= 0:
        parser.error("seconds must be positive")
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("command is required")
    return args


def main() -> int:
    args = parse_args()
    child: subprocess.Popen[bytes] | None = None
    forwarded_signal: int | None = None

    def forward(signal_number: int, _frame: object) -> None:
        nonlocal forwarded_signal
        forwarded_signal = signal_number
        if child is not None:
            signal_group(child.pid, signal_number)

    for signal_number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signal_number, forward)

    try:
        child = subprocess.Popen(args.command, start_new_session=True)
    except OSError as error:
        if error.errno == errno.ENOENT:
            print(f"run_bounded: command not found: {args.command[0]}", file=sys.stderr)
            return 127
        raise

    try:
        try:
            status = child.wait(timeout=args.seconds)
        except subprocess.TimeoutExpired:
            stop_group(child.pid)
            child.wait()
            return 124

        # A command may exit after leaving a descendant behind. Clean the
        # private group before returning so it cannot outlive this supervisor.
        if group_exists(child.pid):
            stop_group(child.pid)
        if forwarded_signal is not None:
            return 128 + forwarded_signal
        return status if status >= 0 else 128 - status
    finally:
        if child.poll() is None:
            stop_group(child.pid)
            child.wait()


if __name__ == "__main__":
    raise SystemExit(main())
