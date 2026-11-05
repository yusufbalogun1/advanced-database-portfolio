-- =====================================================================
-- Portfolio 2 - Optimisation: one targeted index per workload query
-- =====================================================================
SET search_path TO kashlink;
\timing on

-- Q1 + Q6b: composite B-tree. Equality column first (wallet_id), then the sort
-- column (posted_at DESC) so "latest 10 for a wallet" is read straight off the
-- index in order: no sort, no full scan.
CREATE INDEX idx_ledger_wallet_posted ON ledger_entry (wallet_id, posted_at DESC);

-- Q2: expression (function-based) index. A normal index on last_name cannot be
-- used for lower(last_name) = ..., so the index stores the lower-cased values.
CREATE INDEX idx_customer_name_ci ON customer (lower(last_name), lower(first_name));

-- Q3: BRIN (Block Range INdex). Transactions are inserted in time order, so
-- created_at is physically correlated with table position. BRIN stores only
-- min/max per block range: tiny compared with a B-tree.
CREATE INDEX brin_txn_created ON txn USING brin (created_at) WITH (pages_per_range = 32);

-- Q4: partial + covering index. Only successful CASH_OUT rows are indexed
-- (about 14% of txn), and INCLUDE carries dest_wallet_id and amount so the
-- query can be answered by an index-only scan without visiting the table.
CREATE INDEX idx_txn_cashout_cover ON txn (created_at)
    INCLUDE (dest_wallet_id, amount)
    WHERE txn_type = 'CASH_OUT' AND status = 'SUCCESS';

-- Q5: partial index on the small "exceptions" set (about 7% of rows).
CREATE INDEX idx_txn_exceptions ON txn (created_at DESC)
    WHERE status IN ('FAILED','PENDING');

VACUUM ANALYZE txn;
VACUUM ANALYZE ledger_entry;
VACUUM ANALYZE customer;

\timing off
\echo '== Index sizes (shows BRIN vs B-tree storage cost) =='
SELECT indexrelname AS index_name, relname AS table_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE schemaname = 'kashlink'
  AND indexrelname IN ('idx_ledger_wallet_posted','idx_customer_name_ci','brin_txn_created',
                       'idx_txn_cashout_cover','idx_txn_exceptions','txn_pkey')
ORDER BY pg_relation_size(indexrelid) DESC;

\echo '== Table sizes for comparison =='
SELECT relname, pg_size_pretty(pg_relation_size(relid)) AS table_size, n_live_tup AS rows
FROM pg_stat_user_tables WHERE schemaname = 'kashlink' AND relname IN ('txn','ledger_entry','customer');
