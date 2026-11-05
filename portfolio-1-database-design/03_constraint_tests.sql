-- =====================================================================
-- Constraint tests: each block attempts an INVALID operation.
-- PASS means the database rejected it, which is the desired behaviour.
-- Run after 02_seed.sql:  psql -d kashlink -f 03_constraint_tests.sql
-- =====================================================================
SET search_path TO kashlink;
SET client_min_messages TO NOTICE;

CREATE OR REPLACE FUNCTION pg_temp.expect_fail(test_name TEXT, stmt TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE stmt;
    RAISE NOTICE 'FAIL  % -> statement was accepted', test_name;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS  % -> rejected [%] %', test_name, SQLSTATE, SQLERRM;
END $$;

\o /dev/null
-- Entity integrity / keys
SELECT pg_temp.expect_fail('T01 duplicate MSISDN (UNIQUE candidate key)',
  $q$INSERT INTO customer (msisdn,first_name,last_name,date_of_birth,country_code)
     VALUES ('2348031110001','Dup','User','1990-01-01','NG')$q$);

SELECT pg_temp.expect_fail('T02 NULL primary key on country',
  $q$INSERT INTO country VALUES (NULL,'Nowhere','XXX','999')$q$);

-- Referential integrity
SELECT pg_temp.expect_fail('T03 customer in unknown country (FK)',
  $q$INSERT INTO customer (msisdn,first_name,last_name,date_of_birth,country_code)
     VALUES ('2348039999999','No','Country','1990-01-01','ZZ')$q$);

SELECT pg_temp.expect_fail('T04 delete country still referenced (FK RESTRICT)',
  $q$DELETE FROM country WHERE country_code = 'NG'$q$);

-- Domain / CHECK constraints
SELECT pg_temp.expect_fail('T05 under-18 customer',
  $q$INSERT INTO customer (msisdn,first_name,last_name,date_of_birth,country_code)
     VALUES ('2348038888888','Young','User', CURRENT_DATE - INTERVAL '10 years','NG')$q$);

SELECT pg_temp.expect_fail('T06 invalid MSISDN format',
  $q$INSERT INTO customer (msisdn,first_name,last_name,date_of_birth,country_code)
     VALUES ('080-ABC','Bad','Phone','1990-01-01','NG')$q$);

SELECT pg_temp.expect_fail('T07 negative wallet balance (no overdraft)',
  $q$UPDATE wallet SET balance = -1 WHERE wallet_id = 1$q$);

SELECT pg_temp.expect_fail('T08 zero-amount transaction',
  $q$INSERT INTO txn (txn_type,source_wallet_id,dest_wallet_id,amount,currency_code,channel)
     VALUES ('P2P',1,2,0,'NGN','APP')$q$);

SELECT pg_temp.expect_fail('T09 transfer to self',
  $q$INSERT INTO txn (txn_type,source_wallet_id,dest_wallet_id,amount,currency_code,channel)
     VALUES ('P2P',1,1,100,'NGN','APP')$q$);

SELECT pg_temp.expect_fail('T10 unknown transaction type',
  $q$INSERT INTO txn (txn_type,source_wallet_id,dest_wallet_id,amount,currency_code,channel)
     VALUES ('LOAN',1,2,100,'NGN','APP')$q$);

-- Business-rule constraints spanning several columns
SELECT pg_temp.expect_fail('T11 wallet with two owners (exclusive arc)',
  $q$INSERT INTO wallet (customer_id, agent_id, currency_code) VALUES (1, 1, 'GHS')$q$);

SELECT pg_temp.expect_fail('T12 wallet with no owner (exclusive arc)',
  $q$INSERT INTO wallet (customer_id, agent_id, currency_code) VALUES (NULL, NULL, 'NGN')$q$);

SELECT pg_temp.expect_fail('T13 second NGN wallet for same customer',
  $q$INSERT INTO wallet (customer_id, currency_code) VALUES (1, 'NGN')$q$);

SELECT pg_temp.expect_fail('T14 REVERSAL without original txn',
  $q$INSERT INTO txn (txn_type,source_wallet_id,dest_wallet_id,amount,currency_code,channel)
     VALUES ('REVERSAL',4,1,100,'NGN','API')$q$);

SELECT pg_temp.expect_fail('T15 FAILED txn without reason',
  $q$INSERT INTO txn (txn_type,source_wallet_id,dest_wallet_id,amount,currency_code,channel,status)
     VALUES ('P2P',1,2,100,'NGN','APP','FAILED')$q$);

SELECT pg_temp.expect_fail('T16 KYC verified_at without verifier',
  $q$UPDATE kyc_document SET verified_at = now() WHERE document_id = 6$q$);

SELECT pg_temp.expect_fail('T17 duplicate transaction reference (idempotency)',
  $q$INSERT INTO txn (txn_ref,txn_type,source_wallet_id,dest_wallet_id,amount,currency_code,channel)
     SELECT txn_ref,'P2P',1,2,100,'NGN','APP' FROM txn WHERE txn_id = 11$q$);

-- ---------------------------------------------------------------------
-- Integrity verification queries (should return the values noted)
-- ---------------------------------------------------------------------
\o
\echo ''
\echo '== V1: Row counts per table =='
SELECT 'customer' AS tbl, count(*) FROM customer UNION ALL
SELECT 'agent', count(*) FROM agent UNION ALL
SELECT 'wallet', count(*) FROM wallet UNION ALL
SELECT 'txn', count(*) FROM txn UNION ALL
SELECT 'ledger_entry', count(*) FROM ledger_entry UNION ALL
SELECT 'kyc_document', count(*) FROM kyc_document;

\echo '== V2: Ledger reconciliation - wallets whose cached balance differs from ledger (expect 0 rows) =='
SELECT w.wallet_id, w.balance,
       COALESCE(SUM(CASE l.direction WHEN 'C' THEN l.amount ELSE -l.amount END),0) AS ledger_balance
FROM wallet w LEFT JOIN ledger_entry l USING (wallet_id)
GROUP BY w.wallet_id, w.balance
HAVING w.balance <> COALESCE(SUM(CASE l.direction WHEN 'C' THEN l.amount ELSE -l.amount END),0);

\echo '== V3: Wallet balances with owner =='
SELECT w.wallet_id,
       COALESCE(c.first_name || ' ' || c.last_name, a.business_name) AS owner,
       CASE WHEN w.customer_id IS NOT NULL THEN 'CUSTOMER' ELSE 'AGENT' END AS owner_type,
       w.currency_code, w.balance, w.status
FROM wallet w
LEFT JOIN customer c ON c.customer_id = w.customer_id
LEFT JOIN agent    a ON a.agent_id    = w.agent_id
ORDER BY w.wallet_id;
