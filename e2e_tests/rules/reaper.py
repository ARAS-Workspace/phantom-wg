"""
Runs a child to be killed, as a child subreaper: the processes the child
leaves behind get this process as their parent, and it reaps them.

    reaper.py <program> <delay> <argv...>

Starts argv, reads its first line of output, waits up to 10 s for a
<program> process whose parent is the child, then SIGKILLs the child <delay>
seconds later. Afterwards it reaps every process under it for up to 30 s and
prints one JSON line: the child's return code ("rc"), the <program> pid it
saw ("program", null when none appeared), the pids it reaped ("reaped") and
the processes still under it at the deadline ("left").
"""

import ctypes
import json
import os
import signal
import subprocess
import sys
import time

PR_SET_CHILD_SUBREAPER = 36


def children(parent: int) -> list[tuple[int, str]]:
    """(pid, comm) of the processes whose parent is `parent`."""
    out = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat") as f:
                stat = f.read()
        except OSError:
            continue
        comm = stat[stat.index("(") + 1:stat.rindex(")")]
        if int(stat[stat.rindex(")") + 2:].split()[1]) == parent:
            out.append((int(entry), comm))
    return out


def main() -> None:
    program, delay, argv = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        sys.exit(f"prctl: {os.strerror(ctypes.get_errno())}")

    child = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    child.stdout.readline()
    seen, start = None, time.monotonic()
    while seen is None and time.monotonic() - start < 10:
        seen = next((pid for pid, comm in children(child.pid) if comm == program), None)
    time.sleep(delay)
    os.kill(child.pid, signal.SIGKILL)
    rc = child.wait()

    reaped, deadline = [], time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            break
        if pid:
            reaped.append(pid)
        else:
            time.sleep(0.01)
    print(json.dumps({"rc": rc, "program": seen, "reaped": reaped,
                      "left": children(os.getpid())}), flush=True)


if __name__ == "__main__":
    main()
