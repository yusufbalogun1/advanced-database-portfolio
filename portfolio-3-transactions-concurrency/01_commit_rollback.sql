-- =====================================================================
-- Portfolio 3 - Part A: COMMIT, ROLLBACK, atomicity, SAVEPOINT,
-- idempotency and optimistic locking (single session, scripted)
-- Run: psql -d kashlink -f 01_commit_rollback.sql
-- Errors in this script are DELIBERATE: they demonstrate rollback.
-- =====================================================================
SET search_path TO kashlink;
\set ada   '\'2348000000001\''
\set bola  '\'2348000000002\''
\set chidi '\'2348000000003\''
\set dayo  '\'2348000000004\''

SELECT demo_reset();
\echo '== Starting balances =='
SELECT name, balance, version FROM demo_wallets;

-- ---------------------------------------------------------------------
\echo ''
\echo '#### DEMO 1 - COMMIT: Ada sends Bola NGN 5,000 ####'
BEGIN;
SELECT p2p_transfer(:ada, :bola, 5000) AS txn_id;
\echo '-- inside the transaction (not yet committed):'
SELECT name, balance FROM demo_wallets WHERE name IN ('Ada','Bola');
COMMIT;
\echo '-- after COMMIT (permanent):'
SELECT name, balance FROM demo_wallets WHERE name IN ('Ada','Bola');
\echo '-- the two ledger rows written by that transaction:'
SELECT l.txn_id, d.name, l.direction, l.amount, l.balance_after
FROM ledger_entry l JOIN demo_wallets d USING (wallet_id)
WHERE l.txn_id = (SELECT max(txn_id) FROM txn WHERE txn_type = 'P2P' AND source_wallet_id IN (SELECT wallet_id FROM demo_wallets))
ORDER BY l.direction DESC;

-- ---------------------------------------------------------------------
\echo ''
\echo '#### DEMO 2 - ROLLBACK: Ada starts sending Bola NGN 7,000, then cancels ####'
BEGIN;
SELECT p2p_transfer(:ada, :bola, 7000) AS txn_id;
\echo '-- inside the transaction, the money appears to have moved:'
SELECT name, balance FROM demo_wallets WHERE name IN ('Ada','Bola');
ROLLBACK;
\echo '-- after ROLLBACK: balances are exactly as after Demo 1, and only Demo 1''s txn exists (count = 1):'
SELECT name, balance FROM demo_wallets WHERE name IN ('Ada','Bola');
SELECT count(*) AS p2p_txns_for_demo_wallets FROM txn
WHERE txn_type = 'P2P' AND source_wallet_id IN (SELECT wallet_id FROM demo_wallets);

-- ---------------------------------------------------------------------
\echo ''
\echo '#### DEMO 3 - ATOMICITY on failure: credit succeeds, debit fails -> nothing is kept ####'
\echo '-- Manual two-step transfer of NGN 2,000,000 from Chidi (who only has 1,000,000) to Dayo.'
\echo '-- Step 1 (credit Dayo) succeeds; Step 2 (debit Chidi) breaks CHECK (balance >= 0).'
BEGIN;
UPDATE wallet SET balance = balance + 2000000 WHERE wallet_id = (SELECT wallet_id FROM demo_wallets WHERE name = 'Dayo');
SELECT name, balance FROM demo_wallets WHERE name = 'Dayo';
UPDATE wallet SET balance = balance - 2000000 WHERE wallet_id = (SELECT wallet_id FROM demo_wallets WHERE name = 'Chidi');
\echo '-- The transaction is now ABORTED: any further statement is refused until ROLLBACK:'
SELECT name, balance FROM demo_wallets;
ROLLBACK;
\echo '-- After ROLLBACK, Dayo did NOT keep the NGN 2,000,000 credit (no money created):'
SELECT name, balance FROM demo_wallets WHERE name IN ('Chidi','Dayo');

-- ---------------------------------------------------------------------
\echo ''
\echo '#### DEMO 4 - Business-rule rollback inside the transfer function ####'
\echo '-- Chidi tries to send NGN 1,500,000 but has NGN 1,000,000:'
SELECT p2p_transfer(:chidi, :dayo, 1500000);
\echo '-- Nothing was written:'
SELECT name, balance FROM demo_wallets WHERE name IN ('Chidi','Dayo');

-- ---------------------------------------------------------------------
\echo ''
\echo '#### DEMO 5 - SAVEPOINT: partial rollback inside a batch ####'
\echo '-- Chidi sends a batch of 3 payments. Payment 2 goes to a FROZEN wallet and fails;'
\echo '-- the savepoint undoes only that payment, the other two are committed.'
UPDATE wallet SET status = 'FROZEN' WHERE wallet_id = (SELECT wallet_id FROM demo_wallets WHERE name = 'Bola');
BEGIN;
SAVEPOINT pay1;
SELECT p2p_transfer(:chidi, :dayo, 10000) AS payment_1;
SAVEPOINT pay2;
SELECT p2p_transfer(:chidi, :bola, 20000) AS payment_2;
ROLLBACK TO SAVEPOINT pay2;
SAVEPOINT pay3;
SELECT p2p_transfer(:chidi, :ada, 30000) AS payment_3;
COMMIT;
UPDATE wallet SET status = 'ACTIVE' WHERE wallet_id = (SELECT wallet_id FROM demo_wallets WHERE name = 'Bola');
\echo '-- Result: Chidi paid 40,000 in total (10,000 + 30,000); payment 2 was undone:'
SELECT name, balance FROM demo_wallets;

-- ---------------------------------------------------------------------
\echo ''
\echo '#### DEMO 6 - Idempotency: the app retries the same request after a timeout ####'
SELECT p2p_transfer(:dayo, :ada, 2500, 'APP', 'aaaaaaaa-0000-4000-8000-000000000001') AS first_attempt;
SELECT p2p_transfer(:dayo, :ada, 2500, 'APP', 'aaaaaaaa-0000-4000-8000-000000000001') AS retry_attempt;
\echo '-- Only ONE transaction exists for that reference, so Dayo was charged once:'
SELECT txn_id, txn_ref, amount, status FROM txn WHERE txn_ref = 'aaaaaaaa-0000-4000-8000-000000000001';

-- ---------------------------------------------------------------------
\echo ''
\echo '#### DEMO 7 - Optimistic locking with the version column ####'
\echo '-- Two support agents open Dayo''s wallet at the same time and both see the same version.'
SELECT version AS version_seen_by_both_agents FROM demo_wallets WHERE name = 'Dayo' \gset
\echo '-- Agent 1 freezes the wallet, only if the version is unchanged -> UPDATE 1 (success)'
UPDATE wallet SET status = 'FROZEN', version = version + 1
WHERE wallet_id = (SELECT wallet_id FROM demo_wallets WHERE name = 'Dayo') AND version = :version_seen_by_both_agents;
\echo '-- Agent 2 tries to change it based on the now-stale version -> UPDATE 0 (conflict detected)'
UPDATE wallet SET status = 'CLOSED', version = version + 1
WHERE wallet_id = (SELECT wallet_id FROM demo_wallets WHERE name = 'Dayo') AND version = :version_seen_by_both_agents;
SELECT name, status, version FROM demo_wallets WHERE name = 'Dayo';
UPDATE wallet SET status = 'ACTIVE' WHERE wallet_id = (SELECT wallet_id FROM demo_wallets WHERE name = 'Dayo');

-- ---------------------------------------------------------------------
\echo ''
\echo '#### FINAL CHECKS ####'
\echo '-- Total money across the 4 demo wallets must still be NGN 4,000,000 (no money created or lost):'
SELECT sum(balance) AS total_demo_money FROM demo_wallets;
\echo '-- Cached balances vs ledger (expect 0 rows):'
SELECT * FROM demo_reconciliation;
