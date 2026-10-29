"""Event consumer: Kafka -> enrich -> PostgreSQL + Elasticsearch.

Delivery semantics are at-least-once:
  * offsets are committed only after BOTH sinks accept the batch
  * Postgres uses ON CONFLICT DO NOTHING and Elasticsearch uses event_id as
    the document _id, so replayed messages don't create duplicates
  * if a sink stays down after retries, the process exits non-zero and
    Kubernetes restarts it from the last committed offset
Malformed messages go to a dead-letter topic instead of blocking the stream.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import sys
import time
from datetime import datetime

import psycopg
from confluent_kafka import Consumer, KafkaError, Producer
from elasticsearch import Elasticsearch, helpers
from prometheus_client import Counter, Histogram, start_http_server

from enrich import RiskConfig, RiskScorer

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s consumer %(message)s",
)
log = logging.getLogger(__name__)

BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
TOPIC = os.getenv("KAFKA_TOPIC", "auth-events")
DLQ_TOPIC = os.getenv("KAFKA_DLQ_TOPIC", "auth-events-dlq")
GROUP_ID = os.getenv("KAFKA_GROUP_ID", "auth-event-consumer")
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "200"))
PG_DSN = os.getenv("PG_DSN", "postgresql://app:app@localhost:5432/events")
ES_URL = os.getenv("ES_URL", "http://localhost:9200")
ES_USER = os.getenv("ES_USER")
ES_PASSWORD = os.getenv("ES_PASSWORD")
ES_INDEX_PREFIX = os.getenv("ES_INDEX_PREFIX", "auth-events")
ES_INDEX_REPLICAS = int(os.getenv("ES_INDEX_REPLICAS", "0"))  # 0 for single-node dev, 1+ in prod
METRICS_PORT = int(os.getenv("METRICS_PORT", "8000"))
WRITE_RETRIES = int(os.getenv("WRITE_RETRIES", "5"))
# Simulated per-batch processing cost. Raise it during load tests so lag builds
# faster than one consumer can drain it, which is what triggers KEDA scaling.
PROCESSING_DELAY_MS = int(os.getenv("PROCESSING_DELAY_MS", "0"))

EVENTS_CONSUMED = Counter("events_consumed_total", "Events written to both sinks")
EVENTS_SUSPICIOUS = Counter("events_suspicious_total", "Events flagged suspicious", ["reason"])
EVENTS_DLQ = Counter("events_dlq_total", "Malformed events sent to the DLQ")
SINK_ERRORS = Counter("sink_errors_total", "Failed sink writes", ["sink"])
BATCH_SECONDS = Histogram("batch_write_seconds", "Time to write one batch to both sinks")
END_TO_END_SECONDS = Histogram(
    "event_end_to_end_seconds",
    "Time from event creation to being written in both sinks",
    buckets=(0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600),
)

DDL = """
CREATE TABLE IF NOT EXISTS auth_events (
    event_id        UUID PRIMARY KEY,
    event_time      TIMESTAMPTZ NOT NULL,
    username        TEXT NOT NULL,
    source_ip       INET NOT NULL,
    country         TEXT,
    application     TEXT,
    auth_method     TEXT,
    outcome         TEXT NOT NULL,
    failure_reason  TEXT,
    user_agent      TEXT,
    risk_score      SMALLINT NOT NULL,
    risk_reasons    TEXT[] NOT NULL DEFAULT '{}',
    suspicious      BOOLEAN NOT NULL,
    ingested_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS auth_events_ip_time ON auth_events (source_ip, event_time DESC);
CREATE INDEX IF NOT EXISTS auth_events_user_time ON auth_events (username, event_time DESC);
CREATE INDEX IF NOT EXISTS auth_events_suspicious ON auth_events (event_time DESC) WHERE suspicious;
"""

INSERT = """
INSERT INTO auth_events (event_id, event_time, username, source_ip, country, application,
                         auth_method, outcome, failure_reason, user_agent,
                         risk_score, risk_reasons, suspicious)
VALUES (%(event_id)s, %(event_time)s, %(user)s, %(source_ip)s, %(country)s, %(application)s,
        %(auth_method)s, %(outcome)s, %(failure_reason)s, %(user_agent)s,
        %(risk_score)s, %(risk_reasons)s, %(suspicious)s)
ON CONFLICT (event_id) DO NOTHING
"""

INDEX_TEMPLATE = {
    "index_patterns": [f"{ES_INDEX_PREFIX}-*"],
    "template": {
        "settings": {"number_of_shards": 1, "number_of_replicas": ES_INDEX_REPLICAS},
        "mappings": {
            "properties": {
                "event_id": {"type": "keyword"},
                "event_time": {"type": "date"},
                "user": {"type": "keyword"},
                "source_ip": {"type": "ip"},
                "country": {"type": "keyword"},
                "application": {"type": "keyword"},
                "auth_method": {"type": "keyword"},
                "outcome": {"type": "keyword"},
                "failure_reason": {"type": "keyword"},
                "user_agent": {"type": "text", "fields": {"raw": {"type": "keyword"}}},
                "risk_score": {"type": "short"},
                "risk_reasons": {"type": "keyword"},
                "suspicious": {"type": "boolean"},
            }
        },
    },
}

REQUIRED_FIELDS = ("event_id", "timestamp", "user", "source_ip", "outcome")


def with_retries(name: str, fn, attempts: int = WRITE_RETRIES):
    """Run fn with exponential backoff. Re-raises after the last attempt."""
    for attempt in range(1, attempts + 1):
        try:
            return fn()
        except Exception as exc:  # sinks raise many different exception types
            SINK_ERRORS.labels(sink=name).inc()
            if attempt == attempts:
                raise
            wait = min(2 ** attempt, 30)
            log.warning("%s failed (attempt %d/%d): %s; retrying in %ss", name, attempt, attempts, exc, wait)
            time.sleep(wait)
    return None


class EventConsumer:
    def __init__(self) -> None:
        self.running = True
        self.scorer = RiskScorer(RiskConfig())

        self.consumer = Consumer({
            "bootstrap.servers": BOOTSTRAP,
            "group.id": GROUP_ID,
            "enable.auto.commit": False,      # commit manually after sinks succeed
            "auto.offset.reset": "earliest",
            "partition.assignment.strategy": "cooperative-sticky",
        })
        self.dlq = Producer({"bootstrap.servers": BOOTSTRAP, "acks": "all"})

        self.pg = with_retries("postgres-connect", lambda: psycopg.connect(PG_DSN, autocommit=False), attempts=20)
        with self.pg.cursor() as cur:
            cur.execute(DDL)
        self.pg.commit()

        auth = (ES_USER, ES_PASSWORD) if ES_USER and ES_PASSWORD else None
        self.es = Elasticsearch(ES_URL, basic_auth=auth, request_timeout=30)
        with_retries("elasticsearch-connect", self._es_ready, attempts=20)
        self.es.indices.put_index_template(name=ES_INDEX_PREFIX, **INDEX_TEMPLATE)

        signal.signal(signal.SIGTERM, self._stop)
        signal.signal(signal.SIGINT, self._stop)

    def _es_ready(self):
        if not self.es.ping():
            raise ConnectionError(f"Elasticsearch not reachable at {ES_URL}")

    def _stop(self, *_):
        log.info("shutdown signal received")
        self.running = False

    # ---- parsing -----------------------------------------------------------------

    def _parse(self, msg) -> dict | None:
        try:
            event = json.loads(msg.value())
            missing = [f for f in REQUIRED_FIELDS if not event.get(f)]
            if missing:
                raise ValueError(f"missing fields: {missing}")
            datetime.fromisoformat(event["timestamp"])
            return event
        except (ValueError, TypeError) as exc:
            log.warning("sending malformed message to DLQ: %s", exc)
            self.dlq.produce(DLQ_TOPIC, key=msg.key(), value=msg.value(),
                             headers={"error": str(exc)[:200]})
            EVENTS_DLQ.inc()
            return None

    # ---- sinks -------------------------------------------------------------------

    def _write_postgres(self, events: list[dict]) -> None:
        try:
            with self.pg.cursor() as cur:
                cur.executemany(INSERT, events)
            self.pg.commit()
        except Exception:
            self.pg.rollback()
            raise

    def _write_elasticsearch(self, events: list[dict]) -> None:
        actions = [
            {
                "_op_type": "index",
                "_index": f"{ES_INDEX_PREFIX}-{e['event_time'][:10].replace('-', '.')}",
                "_id": e["event_id"],
                "_source": {k: v for k, v in e.items() if k != "timestamp"},
            }
            for e in events
        ]
        helpers.bulk(self.es, actions, raise_on_error=True)

    # ---- main loop ---------------------------------------------------------------

    def run(self) -> None:
        self.consumer.subscribe([TOPIC])
        log.info("consuming %s from %s as group %s", TOPIC, BOOTSTRAP, GROUP_ID)

        try:
            while self.running:
                messages = self.consumer.consume(num_messages=BATCH_SIZE, timeout=1.0)
                if not messages:
                    continue

                events = []
                for msg in messages:
                    if msg.error():
                        if msg.error().code() != KafkaError._PARTITION_EOF:
                            log.error("kafka error: %s", msg.error())
                        continue
                    event = self._parse(msg)
                    if event is not None:
                        events.append(self.scorer.score(event))

                if events:
                    if PROCESSING_DELAY_MS:
                        time.sleep(PROCESSING_DELAY_MS / 1000)

                    with BATCH_SECONDS.time():
                        with_retries("postgres", lambda batch=events: self._write_postgres(batch))
                        with_retries("elasticsearch", lambda batch=events: self._write_elasticsearch(batch))

                    EVENTS_CONSUMED.inc(len(events))
                    written_at = time.time()
                    for e in events:
                        END_TO_END_SECONDS.observe(written_at - datetime.fromisoformat(e["event_time"]).timestamp())
                    for e in events:
                        if e["suspicious"]:
                            for reason in e["risk_reasons"]:
                                EVENTS_SUSPICIOUS.labels(reason=reason).inc()

                self.dlq.flush(5)
                self.consumer.commit(asynchronous=False)
        except Exception:
            # Exit without committing; Kubernetes restarts the pod and it
            # resumes from the last committed offset.
            log.exception("unrecoverable error, exiting so the pod restarts")
            sys.exit(1)
        finally:
            self.consumer.close()
            self.pg.close()
            log.info("consumer stopped")


if __name__ == "__main__":
    start_http_server(METRICS_PORT)
    EventConsumer().run()
