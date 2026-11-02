"""
Memory probe for test_r6_size's test_the_bridge_grows_no_memory_over_cycles;
it judges nothing of the bridge. Collected only with
-o python_files="test_*.py zz_*.py", after every test_*.py of this directory,
or alone with -k memprobe. Its lines start with MEMPROBE.

Once: the kernel, the CPUs and the transparent hugepage settings. At the end
of each of six cycles of 5000 rules in ten presets applied while started and
removed: VmRSS, RssAnon and AnonHugePages of this process; the bytes glibc's
malloc has in use (mallinfo2 uordblks + hblkhd), its heap (arena) and the
free bytes in that heap (fordblks); the blocks Python has allocated
(sys.getallocatedblocks). The second test does the same with malloc_trim(0)
before each reading.
"""

from __future__ import annotations

import ctypes
import os
import sys

from firewall_bridge.presets import apply_preset, remove_preset

from e2e_tests.rules import oracle
from e2e_tests.rules.test_r6_size import _kernel_rules, _specs

CYCLES = 6


class _Mallinfo2(ctypes.Structure):
    _fields_ = [(name, ctypes.c_size_t) for name in (
        "arena", "ordblks", "smblks", "hblks", "hblkhd",
        "usmblks", "fsmblks", "uordblks", "fordblks", "keepcost")]


_libc = ctypes.CDLL("libc.so.6")
_libc.mallinfo2.restype = _Mallinfo2
_libc.malloc_trim.argtypes = [ctypes.c_size_t]


def _kb(path: str, key: str) -> int:
    with open(path) as f:
        return int(next(line for line in f if line.startswith(key + ":")).split()[1])


def _read(path: str) -> str:
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError as e:
        return f"unreadable ({e.strerror})"


def _sample(cycle: int) -> str:
    m = _libc.mallinfo2()
    return (f"cycle={cycle} rss={_kb('/proc/self/status', 'VmRSS')} "
            f"anon={_kb('/proc/self/status', 'RssAnon')} "
            f"anonhuge={_kb('/proc/self/smaps_rollup', 'AnonHugePages')} "
            f"inuse={(m.uordblks + m.hblkhd) // 1024} heap={m.arena // 1024} "
            f"free={m.fordblks // 1024} pyblocks={sys.getallocatedblocks()}")


def _cycles(bridge, db_path, meter, label: str, trim: bool) -> None:
    print(f"\nMEMPROBE {label} kernel={os.uname().release} cpus={os.cpu_count()} "
          f"thp={_read('/sys/kernel/mm/transparent_hugepage/enabled')!r} "
          f"defrag={_read('/sys/kernel/mm/transparent_hugepage/defrag')!r}", flush=True)
    bridge.start()
    for cycle in range(1, CYCLES + 1):
        specs = _specs(5000)
        for spec in specs:
            apply_preset(bridge, spec)
        assert _kernel_rules() == 5000
        for spec in specs:
            remove_preset(bridge, spec["name"])
        if trim:
            _libc.malloc_trim(0)
        print(f"MEMPROBE {label} {_sample(cycle)}", flush=True)
    oracle.check(bridge, db_path, meter, oracle.Ledger(bridge))
    assert _kernel_rules() == 0


def test_memprobe_cycles(bridge, db_path, meter):
    _cycles(bridge, db_path, meter, "untrimmed", trim=False)


def test_memprobe_cycles_trimmed(bridge, db_path, meter):
    _cycles(bridge, db_path, meter, "trimmed", trim=True)
