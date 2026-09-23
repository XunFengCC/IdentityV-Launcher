#!/usr/bin/env python3
"""Bounded real-process tests; no game, permissions, or hardware changes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

binary = Path(__file__).with_name("idv-dense-metrics")


def wait_for(predicate, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.03)
    raise AssertionError("timed out waiting for lifecycle event")


def reason(path):
    try:
        last = json.loads(path.read_text().splitlines()[-1])
        return last.get("reason")
    except (OSError, IndexError, ValueError):
        return None


with tempfile.TemporaryDirectory(prefix="idv-dense-lifecycle-") as directory:
    root = Path(directory)
    children = []
    target = subprocess.Popen(["/bin/sleep", "30"])
    children.append(target)

    def start(name, *args):
        path = root / f"{name}.jsonl"
        process = subprocess.Popen([str(binary), "--pid", str(target.pid), "--output", str(path), *args])
        children.append(process)
        return process, path

    try:
        finite, path = start("finite", "--seconds", "0.15")
        assert finite.wait(timeout=3) == 0 and reason(path) == "time-limit"

        # Both the GUI's explicit zero and the CLI default keep running past
        # the finite control; values above the former two-hour ceiling work.
        for name, args in (("zero", ("--seconds", "0")), ("default", ()), ("long", ("--seconds", "7201"))):
            process, path = start(name, *args, "--parent-pid", str(os.getpid()))
            wait_for(lambda: path.exists() and path.stat().st_size > 100)
            time.sleep(0.25)
            assert process.poll() is None
            process.terminate()
            assert process.wait(timeout=3) == 0 and reason(path) == "signal"

        # A GUI crash/quit must not leave an unlimited orphan sampler.
        parent_path = root / "parent-exit.jsonl"
        bridge = subprocess.Popen([sys.executable, "-c", """
import os, pathlib, subprocess, sys, time
out=pathlib.Path(sys.argv[3])
p=subprocess.Popen([sys.argv[1], '--pid', sys.argv[2], '--output', str(out), '--seconds', '0', '--parent-pid', str(os.getpid())])
deadline=time.monotonic()+3
while time.monotonic()<deadline and not (out.exists() and out.stat().st_size>100): time.sleep(0.02)
if not out.exists() or out.stat().st_size<=100:
    p.terminate(); p.wait(); sys.exit(1)
""", str(binary), str(target.pid), str(parent_path)])
        children.append(bridge)
        assert bridge.wait(timeout=4) == 0
        wait_for(lambda: reason(parent_path) == "parent-exited")

        process, path = start("target-exit", "--seconds", "0")
        wait_for(lambda: path.exists() and path.stat().st_size > 100)
        target.terminate(); target.wait(timeout=2)
        assert process.wait(timeout=3) == 0 and reason(path) == "target-exited"
        print("Dense lifecycle: finite, unlimited/default, >2h opt-in, signal, parent exit and target exit passed")
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=3)
