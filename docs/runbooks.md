# Runbooks

One section per alert in `platform/apps/base/alerts.yaml`. Each follows the same shape: what it means, how to check, how to fix.

Handy commands used throughout:

```bash
kubectl get pods -n pipeline
kubectl logs -n pipeline -l app.kubernetes.io/name=consumer --since=15m
kubectl get hpa,scaledobject -n pipeline
flux get helmreleases -n pipeline
make ui        # Grafana, Prometheus, Alertmanager
```

---

## ConsumerLagHigh

**Meaning:** The consumer group is more than 5,000 messages behind and has been for 10 minutes, despite autoscaling.

**Check**
1. Grafana > Event Pipeline: is lag still climbing or slowly draining?
2. `kubectl get hpa keda-hpa-consumer -n pipeline`: are replicas at the max? If yes, see [ConsumerAtMaxReplicas](#consumeratmaxreplicas).
3. Batch write latency panel: if it spiked, a sink is slow, not the consumer.
4. Consumer logs for `retrying` lines.

**Fix**
* Sink is slow: check Postgres and Elasticsearch health (`make status`). The consumer is only as fast as its slowest sink.
* Load spike: lag will drain on its own once traffic drops. Confirm it's trending down.
* Sustained higher load: raise `maxReplicas` (up to the partition count) or add partitions to the topic.

---

## ConsumerAtMaxReplicas

**Meaning:** KEDA has scaled the consumer to `maxReplicas` and kept it there for 15 minutes.

**Check**
1. Compare max replicas to the topic's partition count: `kubectl get kafkatopic auth-events -n pipeline -o jsonpath='{.spec.partitions}'`. Consumers beyond the partition count sit idle, so there's no point scaling past it.
2. Check whether lag is still growing or stable at the max.

**Fix**
* Increase partitions in `platform/apps/base/kafka.yaml` (partitions can only go up, never down), then raise `maxReplicas` in the consumer HelmRelease to match. Commit and let Flux apply it.
* Check node capacity: `kubectl describe nodes | grep -A5 "Allocated resources"`. New consumer pods may be stuck Pending.

---

## PipelineStalled

**Meaning:** The producer is sending events but the consumer has written nothing for 5 minutes. **Critical.**

**Check**
1. `kubectl get pods -n pipeline -l app.kubernetes.io/name=consumer`: are the pods running, restarting, or Pending?
2. Logs from the previous container if it restarted: `kubectl logs -n pipeline <pod> --previous`
3. Is a sink down? `kubectl get cluster.postgresql.cnpg.io,elasticsearch -n pipeline`
4. Is Kafka healthy? `kubectl get kafka events -n pipeline`

**Fix**
* Consumer exits on `unrecoverable error`: the logs name the sink. Restore that sink and the consumer resumes from its last committed offset with no data loss.
* Pods Pending: node capacity or a PVC issue. `kubectl describe pod` shows why.
* Image pull errors after a deploy: roll back by reverting the tag-bump commit in Git.

---

## EndToEndLatencyHigh

**Meaning:** p95 time from event creation to landing in both sinks is over 60 seconds.

**Check**
1. This almost always follows consumer lag. Check the lag panel first.
2. If lag is low but latency is high, check the batch write latency panel: a sink is responding slowly.

**Fix**
* Follow [ConsumerLagHigh](#consumerlaghigh) or [SinkWriteErrors](#sinkwriteerrors), depending on which one the dashboards point to.

---

## SinkWriteErrors

**Meaning:** More than 5 failed writes to Postgres or Elasticsearch in 5 minutes. The `sink` label says which one.

**Check**
* **Postgres:** `kubectl get cluster events-db -n pipeline`. Is a failover in progress? Check `.status.currentPrimary`.
* **Elasticsearch:** `kubectl get elasticsearch events -n pipeline`. Is health `red` or the phase not `Ready`?
* PVC space: see [PersistentVolumeFillingUp](#persistentvolumefillingup).

**Fix**
* A Postgres failover usually clears within a minute; the consumer retries through it.
* Elasticsearch out of disk goes read-only. Expand the PVC (the gp3 StorageClass allows expansion) or delete old daily indices.
* No action is needed for data integrity: offsets aren't committed until both writes succeed, and writes are idempotent.

---

## DeadLetterQueueReceiving

**Meaning:** Some messages failed validation (bad JSON or missing fields) and were sent to `auth-events-dlq`. **Info only**; the pipeline keeps running.

**Check**
Read a few DLQ messages and their `error` header:
```bash
kubectl exec -n pipeline events-dual-role-0 -- \
  bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic auth-events-dlq --from-beginning --max-messages 5 \
  --property print.headers=true
```

**Fix**
* Fix the producer (or upstream system) sending bad data.
* Replay is manual by design: once fixed, re-publish DLQ messages to `auth-events`.

---

## PipelinePodCrashLooping

**Meaning:** A pod in the `pipeline` namespace restarted more than 3 times in 15 minutes.

**Check**
```bash
kubectl get pods -n pipeline --sort-by='.status.containerStatuses[0].restartCount'
kubectl describe pod <pod> -n pipeline     # look at Last State and Events
kubectl logs <pod> -n pipeline --previous
```

**Fix**
* `OOMKilled`: raise the memory limit in the relevant HelmRelease or operator resource and commit.
* Failing liveness probe: the app is hung. Logs before the restart usually say why.
* Bad config after a deploy: revert the commit in Git and let Flux roll back.

---

## KafkaUnderReplicatedPartitions

**Meaning:** One or more partitions have fewer in-sync replicas than configured. **Critical** because with `min.insync.replicas=2`, losing another broker would block writes.

**Check**
```bash
kubectl get pods -n pipeline -l strimzi.io/cluster=events
kubectl get kafka events -n pipeline -o jsonpath='{.status.conditions}'
```

**Fix**
* A broker is down or restarting: Strimzi usually recovers it. Check its pod events if it doesn't.
* Spot node was reclaimed: the broker reschedules once a node is available in the same AZ as its EBS volume.
* Persistent: check broker logs for disk-full or network errors.

---

## PersistentVolumeFillingUp

**Meaning:** A Kafka, Postgres, or Elasticsearch volume has less than 15% free space.

**Check**
```bash
kubectl get pvc -n pipeline
```

**Fix**
* Expand the volume in Git (the size field in `kafka.yaml`, `postgres.yaml`, or `elasticsearch.yaml`). The gp3 StorageClass has `allowVolumeExpansion: true`.
* Kafka: lower `retention.ms` on the topic.
* Elasticsearch: delete old daily `auth-events-*` indices, or add an ILM policy.
