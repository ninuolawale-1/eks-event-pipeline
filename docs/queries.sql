-- ============================================================================
-- PostgreSQL operational queries
-- Connect: kubectl exec -it -n pipeline <primary-pod> -c postgres -- psql -U postgres -d events
-- (find the primary with: kubectl get cluster events-db -n pipeline -o jsonpath='{.status.currentPrimary}')
-- ============================================================================

-- Throughput: rows written per minute over the last 30 minutes
SELECT date_trunc('minute', ingested_at) AS minute, count(*) AS rows
FROM auth_events
WHERE ingested_at > now() - interval '30 minutes'
GROUP BY 1
ORDER BY 1 DESC;

-- End-to-end latency measured from the database side (event created -> row written)
SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY ingested_at - event_time) AS p50,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY ingested_at - event_time) AS p95,
       max(ingested_at - event_time)                                         AS worst
FROM auth_events
WHERE ingested_at > now() - interval '15 minutes';

-- Duplicate check after a chaos or load test (should return zero rows)
SELECT event_id, count(*) FROM auth_events GROUP BY event_id HAVING count(*) > 1;

-- Table and index size (watch this alongside the PersistentVolumeFillingUp alert)
SELECT pg_size_pretty(pg_total_relation_size('auth_events')) AS total,
       pg_size_pretty(pg_relation_size('auth_events'))       AS table_only,
       pg_size_pretty(pg_indexes_size('auth_events'))        AS indexes;

-- Replication status (run on the primary): replica lag in bytes
SELECT application_name, state, sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes
FROM pg_stat_replication;

-- What the enrichment step flagged
SELECT reason, count(*)
FROM auth_events, unnest(risk_reasons) AS reason
GROUP BY reason
ORDER BY count(*) DESC;


-- ============================================================================
-- Elasticsearch (make ui, then curl with the elastic password it prints)
-- ============================================================================
--   curl -u elastic:$PASS 'localhost:9200/_cat/indices/auth-events-*?v&s=index'
--   curl -u elastic:$PASS 'localhost:9200/auth-events-*/_count'
--   curl -u elastic:$PASS 'localhost:9200/_cluster/health?pretty'


-- ============================================================================
-- Trino (optional; uncomment trino.yaml in platform/apps/base/kustomization.yaml)
-- Consistency check across both sinks with one SQL query.
-- ============================================================================

SELECT
  (SELECT count(*) FROM postgres.public.auth_events
     WHERE CAST(event_time AS date) = current_date)   AS postgres_rows,
  (SELECT count(*) FROM elastic.default."auth-events-*"
     WHERE CAST(event_time AS date) = current_date)   AS elastic_rows;
