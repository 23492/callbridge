#!/usr/bin/env python3
"""Static proof that the Audio Hijack logic moved into AudioHijackRecorder.swift intact (FND-03).

Compares the "Audio Hijack Control" through "fileIdle" block of the pre-split main.swift
(commit fdee2c7, lines 1619-1803) with Capture/AudioHijackRecorder.swift, as sets of unique
stripped non-blank lines. About 12 lines are rewritten on purpose (the guard on state, the
currentCallID comparisons and resets, the state and icon resets, the finishRecording call and
the notification line); the threshold allows 4 more for small reshaping. More than that means
logic was rewritten instead of moved.

Also requires the timing and command literals that define today's behaviour.
Python 3 stdlib only; runs without a Swift toolchain.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OLD_REF = "fdee2c7:CallBridge/CallBridge/main.swift"
OLD_FIRST, OLD_LAST = 1619, 1803
NEW_FILE = os.path.join(ROOT, "CallBridge", "CallBridge", "Capture", "AudioHijackRecorder.swift")
MAX_MISSING = 16
REQUIRED_LITERALS = [
    '"Voice Chat"',
    "callbridge_ah_state.json",
    "withTimeInterval: 3.0",
    "> 7200",
    "> 10",
    "Thread.sleep(forTimeInterval: 2.0)",
    "seconds: 5",
    "now() + 5",
    "com.rogueamoeba.audiohijack",
    "callbridge_cmd_",
]


def stripped_lines(lines):
    """Strip each line and drop blanks; comment lines are kept."""
    return [line.strip() for line in lines if line.strip()]


def main():
    old_src = subprocess.run(
        ["git", "show", OLD_REF], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout.splitlines()
    old = stripped_lines(old_src[OLD_FIRST - 1:OLD_LAST])

    with open(NEW_FILE, encoding="utf-8") as f:
        new_text = f.read()
    new = set(stripped_lines(new_text.splitlines()))

    missing = []
    for line in old:
        if line not in new and line not in missing:
            missing.append(line)

    unique_old = len(set(old))
    print(f"old block: {unique_old} unique lines, missing from new file: {len(missing)} (max {MAX_MISSING})")
    for line in missing:
        print(f"  MISSING: {line}")

    failed = False
    if len(missing) > MAX_MISSING:
        print(f"FAIL: {len(missing)} old lines missing, more than {MAX_MISSING}: logic was rewritten, not moved")
        failed = True

    for literal in REQUIRED_LITERALS:
        if literal not in new_text:
            print(f"FAIL: required literal absent: {literal}")
            failed = True

    if failed:
        return 1
    print("CARVE-OUT OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
