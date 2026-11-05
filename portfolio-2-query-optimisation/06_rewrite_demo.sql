-- =====================================================================
-- Portfolio 2 - Query rewrite demonstration: NOT IN vs NOT EXISTS
-- Business question: "Which customer wallets have had no activity since
-- 1 August 2026?" (dormant-account report for re-engagement campaigns)
--
-- WARNING: the NOT IN version takes about 2 minutes. Run this script once.
-- =====================================================================
SET search_path TO kashlink;
SET max_parallel_workers_per_gather = 0;
\timing on

\echo '== Why NOT IN is dangerous: one NULL in the list makes every comparison UNKNOWN =='
SELECT 'with NULL in list'    AS test, count(*) AS rows_returned FROM (SELECT 5 AS x) t WHERE x NOT IN (1, 2, NULL)
UNION ALL
SELECT 'without NULL in list',        count(*)                  FROM (SELECT 5 AS x) t WHERE x NOT IN (1, 2);

\echo '== How many NULLs does the subquery produce? (BILL_PAY and float CASH_IN have a NULL side) =='
SELECT count(*) FILTER (WHERE dest_wallet_id IS NULL)   AS null_dest,
       count(*) FILTER (WHERE source_wallet_id IS NULL) AS null_source
FROM txn WHERE created_at >= '2026-08-01';

\echo '== Q6a ORIGINAL: NOT IN (slow AND wrong) =='
SELECT count(*) AS dormant_wallets FROM wallet w
WHERE w.customer_id IS NOT NULL
  AND w.wallet_id NOT IN (SELECT source_wallet_id FROM txn WHERE created_at >= '2026-08-01'
                          UNION
                          SELECT dest_wallet_id   FROM txn WHERE created_at >= '2026-08-01');

\echo '== Q6b REWRITTEN: NOT EXISTS against the ledger (fast AND correct) =='
SELECT count(*) AS dormant_wallets FROM wallet w
WHERE w.customer_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM ledger_entry l
                  WHERE l.wallet_id = w.wallet_id AND l.posted_at >= '2026-08-01');

\echo '== Q6b sample output: 10 dormant wallets with owner and last activity =='
SELECT w.wallet_id, c.first_name || ' ' || c.last_name AS customer, c.msisdn, w.balance,
       (SELECT max(posted_at) FROM ledger_entry l WHERE l.wallet_id = w.wallet_id) AS last_activity
FROM wallet w JOIN customer c ON c.customer_id = w.customer_id
WHERE NOT EXISTS (SELECT 1 FROM ledger_entry l
                  WHERE l.wallet_id = w.wallet_id AND l.posted_at >= '2026-08-01')
ORDER BY last_activity NULLS FIRST
LIMIT 10;

RESET max_parallel_workers_per_gather;
