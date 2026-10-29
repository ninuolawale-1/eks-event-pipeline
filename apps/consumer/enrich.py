"""Lightweight event enrichment.

Flags source IPs with a burst of failed logins in a sliding window. The rules
are deliberately simple; the point of this project is the platform that runs
them, not the detection logic.

Kept free of Kafka, Postgres, and Elasticsearch imports so it can be unit
tested on its own (see tests/test_enrich.py).

State is per consumer process. Because the producer keys messages by source
IP, all events for a given IP land on the same partition and therefore the
same consumer, so per-IP windows stay accurate as KEDA scales consumers out.
"""

from __future__ import annotations

from collections import defaultdict, deque
from dataclasses import dataclass
from datetime import datetime


@dataclass
class RiskConfig:
    window_seconds: int = 300
    repeated_failures: int = 5
    brute_force_failures: int = 10
    suspicious_threshold: int = 50


class RiskScorer:
    def __init__(self, config: RiskConfig | None = None) -> None:
        self.cfg = config or RiskConfig()
        # source_ip -> deque of failure timestamps (epoch seconds)
        self._failures: dict[str, deque] = defaultdict(deque)

    def _prune(self, ip: str, now: float) -> deque:
        window = self._failures[ip]
        cutoff = now - self.cfg.window_seconds
        while window and window[0] < cutoff:
            window.popleft()
        return window

    def score(self, event: dict) -> dict:
        """Return a copy of the event with event_time, risk_score, risk_reasons, suspicious."""
        ts = datetime.fromisoformat(event["timestamp"])
        now = ts.timestamp()
        ip = event["source_ip"]
        failed = event.get("outcome") == "failure"

        window = self._prune(ip, now)
        prior_failures = len(window)
        if failed:
            window.append(now)
        elif not window:
            # Don't keep empty windows around for every IP ever seen
            self._failures.pop(ip, None)

        score, reasons = 0, []
        failures = len(window)

        if failures >= self.cfg.brute_force_failures:
            score, reasons = 60, ["brute_force"]
        elif failures >= self.cfg.repeated_failures:
            score, reasons = 30, ["repeated_failures"]

        if not failed and prior_failures >= self.cfg.repeated_failures:
            score += 40
            reasons.append("success_after_failures")

        score = min(score, 100)
        enriched = dict(event)
        enriched.update(
            event_time=ts.isoformat(),
            risk_score=score,
            risk_reasons=reasons,
            suspicious=score >= self.cfg.suspicious_threshold,
        )
        return enriched
