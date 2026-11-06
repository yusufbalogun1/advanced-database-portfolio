SET search_path TO kashlink;
SELECT max(wallet_id) FILTER (WHERE name = 'Ada')  AS ada,
       max(wallet_id) FILTER (WHERE name = 'Bola') AS bola
FROM demo_wallets \gset
\echo 'Ready. Wallet ids loaded as :ada and :bola'
SHOW transaction_isolation;
