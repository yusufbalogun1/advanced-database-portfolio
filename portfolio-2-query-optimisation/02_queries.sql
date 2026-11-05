-- =====================================================================
-- Portfolio 2 - The six workload queries and their RESULTS
-- These represent real KashLink operations: app statement screen,
-- customer-support search, finance reporting, agent management,
-- operations monitoring and marketing (dormant accounts).
-- =====================================================================
SET search_path TO kashlink;
\timing on

\echo '== Q1: Mini-statement - last 10 movements for wallet 20000 (customer app) =='
SELECT l.posted_at, l.direction, l.amount, l.balance_after
FROM ledger_entry l
WHERE l.wallet_id = 20000
ORDER BY l.posted_at DESC
LIMIT 10;

\echo '== Q2: Support search - customers named Yusuf Balogun (case-insensitive) =='
SELECT customer_id, msisdn, first_name, last_name
FROM customer
WHERE lower(last_name) = 'balogun' AND lower(first_name) = 'yusuf'
ORDER BY customer_id
LIMIT 10;

\echo '== Q3: Finance - October 2026 volume by channel and type (successful only) =='
SELECT channel, txn_type, count(*) AS txn_count, sum(amount) AS total_value
FROM txn
WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01' AND status = 'SUCCESS'
GROUP BY channel, txn_type
ORDER BY channel, txn_type;

\echo '== Q4: Agent management - top 10 agents by cash-out value, last 30 days =='
SELECT a.agent_code, a.city, count(*) AS cash_outs, sum(t.amount) AS value
FROM txn t
JOIN wallet w ON w.wallet_id = t.dest_wallet_id
JOIN agent  a ON a.agent_id  = w.agent_id
WHERE t.txn_type = 'CASH_OUT' AND t.status = 'SUCCESS'
  AND t.created_at >= TIMESTAMPTZ '2026-11-01 00:00+01' - INTERVAL '30 days'
GROUP BY a.agent_code, a.city
ORDER BY value DESC
LIMIT 10;

\echo '== Q5: Operations - latest failed/pending transactions, last 7 days =='
SELECT txn_id, txn_type, amount, status, failure_reason, created_at
FROM txn
WHERE status IN ('FAILED','PENDING')
  AND created_at >= TIMESTAMPTZ '2026-11-01 00:00+01' - INTERVAL '7 days'
ORDER BY created_at DESC
LIMIT 15;

\echo '== Q5b: Failure reasons breakdown, last 7 days =='
SELECT failure_reason, count(*)
FROM txn
WHERE status = 'FAILED' AND created_at >= TIMESTAMPTZ '2026-11-01 00:00+01' - INTERVAL '7 days'
GROUP BY failure_reason ORDER BY count(*) DESC;

\echo '== Q6: Marketing - number of dormant customer wallets (no activity since 1 Aug 2026) =='
SELECT count(*) AS dormant_wallets
FROM wallet w
WHERE w.customer_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM ledger_entry l
                  WHERE l.wallet_id = w.wallet_id AND l.posted_at >= '2026-08-01');
