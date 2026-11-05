-- =====================================================================
-- Shared file: EXPLAIN (ANALYZE, BUFFERS) for the six workload queries.
-- Included by 03_explain_baseline.sql and 05_explain_optimised.sql.
-- Each query is run once silently first so the cache is warm and the
-- before/after comparison is fair.
-- =====================================================================
SET search_path TO kashlink;
SET max_parallel_workers_per_gather = 0;   -- single-process plans: easier to read and compare

\echo '================ Q1: Mini-statement (last 10 movements for one wallet) ================'
\o /dev/null
SELECT l.posted_at, l.direction, l.amount, l.balance_after FROM ledger_entry l
WHERE l.wallet_id = 20000 ORDER BY l.posted_at DESC LIMIT 10;
\o
EXPLAIN (ANALYZE, BUFFERS, COSTS)
SELECT l.posted_at, l.direction, l.amount, l.balance_after FROM ledger_entry l
WHERE l.wallet_id = 20000 ORDER BY l.posted_at DESC LIMIT 10;

\echo '================ Q2: Case-insensitive customer search by name ================'
\o /dev/null
SELECT customer_id, msisdn, first_name, last_name FROM customer
WHERE lower(last_name) = 'balogun' AND lower(first_name) = 'yusuf';
\o
EXPLAIN (ANALYZE, BUFFERS, COSTS)
SELECT customer_id, msisdn, first_name, last_name FROM customer
WHERE lower(last_name) = 'balogun' AND lower(first_name) = 'yusuf';

\echo '================ Q3: October 2026 channel report (successful txns) ================'
\o /dev/null
SELECT channel, txn_type, count(*), sum(amount) FROM txn
WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01' AND status = 'SUCCESS'
GROUP BY channel, txn_type;
\o
EXPLAIN (ANALYZE, BUFFERS, COSTS)
SELECT channel, txn_type, count(*), sum(amount) FROM txn
WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01' AND status = 'SUCCESS'
GROUP BY channel, txn_type;

\echo '================ Q4: Top 10 agents by cash-out value, last 30 days ================'
\o /dev/null
SELECT a.agent_code, a.city, count(*) AS cash_outs, sum(t.amount) AS value
FROM txn t JOIN wallet w ON w.wallet_id = t.dest_wallet_id JOIN agent a ON a.agent_id = w.agent_id
WHERE t.txn_type = 'CASH_OUT' AND t.status = 'SUCCESS'
  AND t.created_at >= TIMESTAMPTZ '2026-11-01 00:00+01' - INTERVAL '30 days'
GROUP BY a.agent_code, a.city ORDER BY value DESC LIMIT 10;
\o
EXPLAIN (ANALYZE, BUFFERS, COSTS)
SELECT a.agent_code, a.city, count(*) AS cash_outs, sum(t.amount) AS value
FROM txn t JOIN wallet w ON w.wallet_id = t.dest_wallet_id JOIN agent a ON a.agent_id = w.agent_id
WHERE t.txn_type = 'CASH_OUT' AND t.status = 'SUCCESS'
  AND t.created_at >= TIMESTAMPTZ '2026-11-01 00:00+01' - INTERVAL '30 days'
GROUP BY a.agent_code, a.city ORDER BY value DESC LIMIT 10;

\echo '================ Q5: Ops monitor - failed/pending txns in the last 7 days ================'
\o /dev/null
SELECT txn_id, txn_type, amount, status, failure_reason, created_at FROM txn
WHERE status IN ('FAILED','PENDING') AND created_at >= TIMESTAMPTZ '2026-11-01 00:00+01' - INTERVAL '7 days'
ORDER BY created_at DESC LIMIT 50;
\o
EXPLAIN (ANALYZE, BUFFERS, COSTS)
SELECT txn_id, txn_type, amount, status, failure_reason, created_at FROM txn
WHERE status IN ('FAILED','PENDING') AND created_at >= TIMESTAMPTZ '2026-11-01 00:00+01' - INTERVAL '7 days'
ORDER BY created_at DESC LIMIT 50;

\echo '================ Q6a: Dormant wallets - ORIGINAL (NOT IN) - estimated plan only ================'
\echo '(EXPLAIN without ANALYZE: running it takes ~2 minutes. See 06_rewrite_demo.sql for the timed run.)'
EXPLAIN (COSTS)
SELECT count(*) FROM wallet w
WHERE w.customer_id IS NOT NULL
  AND w.wallet_id NOT IN (SELECT source_wallet_id FROM txn WHERE created_at >= '2026-08-01'
                          UNION
                          SELECT dest_wallet_id   FROM txn WHERE created_at >= '2026-08-01');

\echo '================ Q6b: Dormant wallets - REWRITTEN (NOT EXISTS on ledger) ================'
EXPLAIN (ANALYZE, BUFFERS, COSTS)
SELECT count(*) FROM wallet w
WHERE w.customer_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM ledger_entry l
                  WHERE l.wallet_id = w.wallet_id AND l.posted_at >= '2026-08-01');

RESET max_parallel_workers_per_gather;
