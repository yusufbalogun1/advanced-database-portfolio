SET search_path TO kashlink;
\echo '-- Expected after 1,000 transfers of NGN 100: Ada 900,000.00 | Bola 1,100,000.00 | Total 2,000,000.00'
SELECT name, balance,
       CASE name WHEN 'Ada' THEN 900000 ELSE 1100000 END AS expected,
       balance - CASE name WHEN 'Ada' THEN 900000 ELSE 1100000 END AS error
FROM demo_wallets WHERE name IN ('Ada','Bola');
SELECT sum(balance) AS total_ada_plus_bola, sum(balance) - 2000000 AS money_created_or_lost
FROM demo_wallets WHERE name IN ('Ada','Bola');
SELECT count(*) AS p2p_txns_recorded FROM txn
WHERE txn_type = 'P2P' AND source_wallet_id = (SELECT wallet_id FROM demo_wallets WHERE name = 'Ada');
\echo '-- Cached balance vs ledger (expect 0 rows if the run was safe):'
SELECT * FROM demo_reconciliation WHERE name IN ('Ada','Bola');
