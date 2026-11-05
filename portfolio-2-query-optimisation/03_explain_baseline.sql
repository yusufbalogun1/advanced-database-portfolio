-- =====================================================================
-- Portfolio 2 - BASELINE execution plans (before optimisation)
-- Drops any Portfolio 2 indexes so the baseline is always reproducible.
-- =====================================================================
SET search_path TO kashlink;

DROP INDEX IF EXISTS idx_ledger_wallet_posted;
DROP INDEX IF EXISTS idx_customer_name_ci;
DROP INDEX IF EXISTS brin_txn_created;
DROP INDEX IF EXISTS idx_txn_cashout_cover;
DROP INDEX IF EXISTS idx_txn_exceptions;
ANALYZE;

\echo '##### BASELINE - only primary keys, unique constraints and Portfolio 1 FK indexes #####'
\ir explain_all.sql
