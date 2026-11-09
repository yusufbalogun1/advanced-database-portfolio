-- =====================================================================
-- Portfolio 5 - Part B: Horizontal partitioning by country (shard design)
-- KashLink's transactions are split by country_code, the proposed SHARD KEY.
-- On one PostgreSQL server this is LIST partitioning; in production each
-- partition would live on an in-country server (e.g. Citus / postgres_fdw shards).
-- Run after Portfolios 1 and 2:  psql -d kashlink -f 02_partitioning.sql
-- =====================================================================
SET search_path TO kashlink;
DROP TABLE IF EXISTS txn_by_country CASCADE;

-- 1. Parent table: the partition key must be part of the primary key
CREATE TABLE txn_by_country (
    txn_id        BIGINT        NOT NULL,
    country_code  CHAR(2)       NOT NULL,
    txn_type      VARCHAR(12)   NOT NULL,
    amount        NUMERIC(18,2) NOT NULL,
    currency_code CHAR(3)       NOT NULL,
    channel       VARCHAR(6)    NOT NULL,
    status        VARCHAR(10)   NOT NULL,
    created_at    TIMESTAMPTZ   NOT NULL,
    PRIMARY KEY (country_code, txn_id)
) PARTITION BY LIST (country_code);

-- 2. One partition ("shard") per operating country
CREATE TABLE txn_ng PARTITION OF txn_by_country FOR VALUES IN ('NG');
CREATE TABLE txn_gh PARTITION OF txn_by_country FOR VALUES IN ('GH');
CREATE TABLE txn_ug PARTITION OF txn_by_country FOR VALUES IN ('UG');
CREATE INDEX ON txn_by_country (created_at);   -- created on every partition automatically

-- 3. Load: each transaction's country comes from the owner of its wallet
INSERT INTO txn_by_country
SELECT t.txn_id, COALESCE(c.country_code, a.country_code), t.txn_type, t.amount, t.currency_code,
       t.channel, t.status, t.created_at
FROM txn t
JOIN wallet w        ON w.wallet_id = COALESCE(t.source_wallet_id, t.dest_wallet_id)
LEFT JOIN customer c ON c.customer_id = w.customer_id
LEFT JOIN agent a    ON a.agent_id    = w.agent_id;
ANALYZE txn_by_country;

\echo '== Rows per partition (the database routed each row automatically) =='
SELECT tableoid::regclass AS partition, count(*) AS rows,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM txn_by_country GROUP BY 1 ORDER BY 2 DESC;

\echo '== Partition sizes =='
SELECT c.relname AS partition, pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = 'kashlink.txn_by_country'::regclass ORDER BY 1;

\echo ''
\echo '== PARTITION PRUNING: a Ghana-only report touches ONLY the Ghana partition =='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT channel, count(*), sum(amount) FROM txn_by_country
WHERE country_code = 'GH' AND created_at >= '2026-10-01' AND status = 'SUCCESS'
GROUP BY channel;

\echo '== WITHOUT the shard key, every partition must be scanned (scatter-gather) =='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT channel, count(*), sum(amount) FROM txn_by_country
WHERE created_at >= '2026-10-01' AND status = 'SUCCESS'
GROUP BY channel;

\echo ''
\echo '== Routing protection: a row for a country with no partition is rejected =='
INSERT INTO txn_by_country VALUES (99999999, 'KE', 'P2P', 100, 'KES', 'APP', 'SUCCESS', now());

\echo '== Expanding to a new market = adding a partition, with no change to existing data =='
CREATE TABLE txn_ke PARTITION OF txn_by_country FOR VALUES IN ('KE');
INSERT INTO txn_by_country VALUES (99999999, 'KE', 'P2P', 100, 'KES', 'APP', 'SUCCESS', now());
SELECT tableoid::regclass AS partition, txn_id, country_code FROM txn_by_country WHERE country_code = 'KE';
DROP TABLE txn_ke;   -- clean up the demonstration partition
