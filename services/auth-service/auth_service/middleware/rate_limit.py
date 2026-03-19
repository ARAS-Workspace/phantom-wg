"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.

In-memory sliding window rate limiter for login endpoint.
"""

from __future__ import annotations

import time
import threading


class RateLimiter:
    """IP-based sliding window rate limiter."""

    __slots__ = ("_window", "_max_attempts", "_attempts", "_lock")

    def __init__(self, window: int = 60, max_attempts: int = 5) -> None:
        self._window = window
        self._max_attempts = max_attempts
        self._attempts: dict[str, list[float]] = {}
        self._lock = threading.Lock()

    def check(self, ip: str) -> bool:
        """Return True if request is allowed, False if rate limited."""
        now = time.time()
        cutoff = now - self._window
        with self._lock:
            timestamps = self._attempts.get(ip, [])
            timestamps = [t for t in timestamps if t > cutoff]
            if len(timestamps) >= self._max_attempts:
                self._attempts[ip] = timestamps
                return False
            timestamps.append(now)
            self._attempts[ip] = timestamps
            return True

    def reset(self, ip: str) -> None:
        """Reset attempts for an IP (on successful login)."""
        with self._lock:
            self._attempts.pop(ip, None)
