"""Synthetic traffic generator for the event pipeline.

Publishes login events to Kafka as JSON at a configurable rate
(EVENTS_PER_SECOND), with occasional bursts of failed logins mixed in so the
consumer's enrichment has something to flag.

Turn EVENTS_PER_SECOND up (or run more replicas) to load-test the pipeline
and watch KEDA scale the consumer.

Messages are keyed by source IP, so every event from one IP lands on the
same partition. That keeps per-IP ordering intact for the consumer's
sliding-window logic, even with several consumer replicas.
"""

from __future__ import annotations

import json
import logging
import os
import random
import signal
import time
import uuid
from datetime import UTC, datetime

from confluent_kafka import Producer
from prometheus_client import Counter, start_http_server

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s producer %(message)s",
)
log = logging.getLogger(__name__)

BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
TOPIC = os.getenv("KAFKA_TOPIC", "auth-events")
EVENTS_PER_SECOND = float(os.getenv("EVENTS_PER_SECOND", "5"))
ATTACK_PROBABILITY = float(os.getenv("ATTACK_PROBABILITY", "0.02"))
METRICS_PORT = int(os.getenv("METRICS_PORT", "8000"))
SEED = os.getenv("RANDOM_SEED")

EVENTS_PRODUCED = Counter("events_produced_total", "Events sent to Kafka", ["outcome"])
ATTACK_BURSTS = Counter("attack_bursts_total", "Simulated attack bursts", ["kind"])
DELIVERY_ERRORS = Counter("delivery_errors_total", "Kafka delivery failures")

USERS = [
    "aaliyah.james", "ben.carter", "chloe.nguyen", "daniel.okafor", "elena.ruiz",
    "farid.haddad", "grace.kim", "henry.walsh", "isabel.costa", "jamal.reed",
    "kara.singh", "liam.obrien", "maya.patel", "noah.fischer", "olivia.chen",
    "priya.raman", "quinn.harper", "rosa.mendez", "sam.adeyemi", "tara.lopez",
    "svc-backup", "svc-deploy", "admin",
]
APPLICATIONS = ["vpn", "email", "hr-portal", "jira", "aws-console", "gitlab"]
AUTH_METHODS = ["password", "mfa_push", "sso", "api_key"]
USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5)",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X)",
    "okhttp/4.12.0",
    "python-requests/2.32.3",
]
FAILURE_REASONS = ["bad_password", "mfa_denied", "account_locked", "unknown_user"]
FOREIGN_COUNTRIES = ["DE", "BR", "IN", "VN", "NL", "RO", "ZA", "KR"]

_rng = random.Random(SEED)

# Each user gets a stable "home" IP so normal traffic looks consistent.
HOME_IPS = {u: f"10.{_rng.randint(0, 20)}.{_rng.randint(0, 255)}.{_rng.randint(2, 254)}" for u in USERS}


def _now() -> str:
    return datetime.now(UTC).isoformat()


def _public_ip() -> str:
    return f"{_rng.randint(23, 223)}.{_rng.randint(0, 255)}.{_rng.randint(0, 255)}.{_rng.randint(1, 254)}"


def make_event(**overrides) -> dict:
    user = overrides.pop("user", _rng.choice(USERS))
    success = _rng.random() < 0.93
    event = {
        "event_id": str(uuid.uuid4()),
        "timestamp": _now(),
        "user": user,
        "source_ip": HOME_IPS[user] if user in HOME_IPS else _public_ip(),
        "country": "US",
        "application": _rng.choice(APPLICATIONS),
        "auth_method": _rng.choices(AUTH_METHODS, weights=[30, 45, 20, 5])[0],
        "outcome": "success" if success else "failure",
        "failure_reason": None if success else _rng.choice(FAILURE_REASONS[:2]),
        "user_agent": _rng.choice(USER_AGENTS[:3]),
    }
    event.update(overrides)
    return event


def brute_force_burst() -> list[dict]:
    """Many failures against one account from one external IP, sometimes ending in a success."""
    target = _rng.choice(USERS)
    ip, country = _public_ip(), _rng.choice(FOREIGN_COUNTRIES)
    attempts = _rng.randint(15, 40)
    common = {
        "user": target, "source_ip": ip, "country": country, "application": "vpn",
        "auth_method": "password", "user_agent": "python-requests/2.32.3",
    }
    events = [make_event(outcome="failure", failure_reason="bad_password", **common)
              for _ in range(attempts)]
    if _rng.random() < 0.15:
        events.append(make_event(outcome="success", failure_reason=None, **common))
    return events


def password_spray_burst() -> list[dict]:
    """One external IP trying a single password against many accounts."""
    ip, country = _public_ip(), _rng.choice(FOREIGN_COUNTRIES)
    targets = _rng.sample(USERS, k=_rng.randint(8, 15))
    return [
        make_event(user=u, source_ip=ip, country=country, application="email",
                   auth_method="password", outcome="failure",
                   failure_reason=_rng.choice(["bad_password", "unknown_user"]),
                   user_agent="okhttp/4.12.0")
        for u in targets
    ]


class EventProducer:
    def __init__(self) -> None:
        self.running = True
        self.producer = Producer({
            "bootstrap.servers": BOOTSTRAP,
            "client.id": "event-producer",
            "queue.buffering.max.messages": 500000,
            "acks": "all",                 # wait for all in-sync replicas
            "enable.idempotence": True,    # no duplicates on retry
            "linger.ms": 20,
            "compression.type": "lz4",
        })
        signal.signal(signal.SIGTERM, self._stop)
        signal.signal(signal.SIGINT, self._stop)

    def _stop(self, *_):
        log.info("shutdown signal received, flushing")
        self.running = False

    @staticmethod
    def _on_delivery(err, msg):
        if err is not None:
            DELIVERY_ERRORS.inc()
            log.error("delivery failed: %s", err)

    def send(self, event: dict) -> None:
        self.producer.produce(
            TOPIC,
            key=event["source_ip"].encode(),
            value=json.dumps(event).encode(),
            on_delivery=self._on_delivery,
        )
        EVENTS_PRODUCED.labels(outcome=event["outcome"]).inc()

    def _emit_one(self) -> None:
        if _rng.random() < ATTACK_PROBABILITY:
            kind = _rng.choice(["brute_force", "password_spray"])
            burst = brute_force_burst() if kind == "brute_force" else password_spray_burst()
            ATTACK_BURSTS.labels(kind=kind).inc()
            log.debug("injecting %s burst (%d events)", kind, len(burst))
            for event in burst:
                self.send(event)
        else:
            self.send(make_event())

    def run(self) -> None:
        """Send events in 100 ms ticks so high rates (hundreds or thousands/sec)
        stay accurate instead of being throttled by per-event sleeps."""
        log.info("producing to %s on %s at ~%s events/sec", TOPIC, BOOTSTRAP, EVENTS_PER_SECOND)
        tick = 0.1
        owed = 0.0
        next_tick = time.monotonic()
        while self.running:
            owed += EVENTS_PER_SECOND * tick
            while owed >= 1:
                self._emit_one()
                owed -= 1
            self.producer.poll(0)  # serve delivery callbacks
            next_tick += tick
            time.sleep(max(0.0, next_tick - time.monotonic()))
        remaining = self.producer.flush(10)
        log.info("stopped, %d messages left unflushed", remaining)


if __name__ == "__main__":
    start_http_server(METRICS_PORT)
    EventProducer().run()
