-- =====================================================================
-- KashLink Mobile Money (simulated) - Sample data
-- All people, numbers and businesses are fictional.
-- Run after 01_schema.sql
-- =====================================================================
SET search_path TO kashlink;

INSERT INTO country VALUES
 ('NG','Nigeria','NGN','234'),
 ('GH','Ghana','GHS','233'),
 ('UG','Uganda','UGX','256');

-- Simplification: limits are expressed in local-currency units.
INSERT INTO kyc_tier VALUES
 (1,'Basic',     300000.00,   50000.00),
 (2,'Standard', 1000000.00,  200000.00),
 (3,'Premium', 10000000.00, 2000000.00);

INSERT INTO staff (full_name, email, staff_role, country_code) VALUES
 ('Adaeze Nwosu',  'adaeze.nwosu@kashlink.example',  'KYC_OFFICER','NG'),
 ('Kwame Mensah',  'kwame.mensah@kashlink.example',  'KYC_OFFICER','GH'),
 ('Tunde Bakare',  'tunde.bakare@kashlink.example',  'FINANCE','NG');

INSERT INTO biller (biller_name, category, country_code) VALUES
 ('Lagos Power Distribution', 'ELECTRICITY','NG'),
 ('StarView TV',              'TV',         'NG'),
 ('KashLink Airtime NG',      'AIRTIME',    'NG'),
 ('Accra Water Co.',          'WATER',      'GH'),
 ('KashLink Airtime GH',      'AIRTIME',    'GH');

INSERT INTO customer (msisdn, first_name, last_name, date_of_birth, email, country_code, tier_level, status) VALUES
 ('2348031110001','Chioma','Okeke',   '1992-03-14','chioma.o@mail.example','NG',2,'ACTIVE'),   -- 1
 ('2348031110002','Ibrahim','Musa',   '1988-07-22',NULL,                   'NG',2,'ACTIVE'),   -- 2
 ('2348031110003','Funmi','Adeyemi',  '1999-11-02',NULL,                   'NG',1,'ACTIVE'),   -- 3
 ('2348031110004','Emeka','Obi',      '1985-01-30','emeka.obi@mail.example','NG',2,'ACTIVE'),  -- 4
 ('2348031110005','Zainab','Bello',   '1979-05-18','z.bello@mail.example', 'NG',3,'ACTIVE'),   -- 5
 ('2348031110006','Segun','Alabi',    '2001-09-09',NULL,                   'NG',1,'ACTIVE'),   -- 6
 ('2348031110007','Ngozi','Eze',      '1995-12-25',NULL,                   'NG',1,'SUSPENDED'),-- 7
 ('233244110008', 'Ama',  'Owusu',    '1990-04-11',NULL,                   'GH',2,'ACTIVE'),   -- 8
 ('233244110009', 'Kofi', 'Asante',   '1987-08-03',NULL,                   'GH',1,'ACTIVE'),   -- 9
 ('256772110010', 'Grace','Namutebi', '1993-02-27',NULL,                   'UG',1,'ACTIVE');   -- 10

INSERT INTO kyc_document (customer_id, document_type, document_ref, submitted_at, verified_by, verified_at) VALUES
 (1,'NATIONAL_ID','NIN-00000001','2026-09-01 10:00+01',1,'2026-09-01 15:00+01'),
 (2,'PASSPORT',   'A00000002',   '2026-09-02 09:00+01',1,'2026-09-03 11:00+01'),
 (4,'NATIONAL_ID','NIN-00000004','2026-09-02 12:00+01',1,'2026-09-02 16:30+01'),
 (5,'PASSPORT',   'A00000005',   '2026-09-03 08:30+01',1,'2026-09-03 09:45+01'),
 (5,'UTILITY_BILL','LPD-778812', '2026-09-03 08:31+01',1,'2026-09-03 09:46+01'),
 (6,'VOTERS_CARD','VIN-00000006','2026-09-10 14:00+01',NULL,NULL),             -- awaiting review
 (8,'NATIONAL_ID','GHA-000000008','2026-09-05 10:00+00',2,'2026-09-05 12:00+00');

INSERT INTO agent (agent_code, business_name, msisdn, country_code, city) VALUES
 ('NG-LAG-001','Mama Tee Ventures',   '2348090000001','NG','Lagos'),   -- 1
 ('NG-ABJ-002','Wuse Phone Hub',      '2348090000002','NG','Abuja'),   -- 2
 ('GH-ACC-001','Osu Corner Shop',     '233200000003', 'GH','Accra');   -- 3

-- Wallets 1-10 belong to customers 1-10, wallets 11-13 to agents 1-3.
INSERT INTO wallet (customer_id, agent_id, currency_code, status)
SELECT c.customer_id, NULL, co.currency_code,
       CASE WHEN c.customer_id = 7 THEN 'FROZEN' ELSE 'ACTIVE' END
FROM customer c JOIN country co USING (country_code)
ORDER BY c.customer_id;

INSERT INTO wallet (customer_id, agent_id, currency_code)
SELECT NULL, a.agent_id, co.currency_code
FROM agent a JOIN country co USING (country_code)
ORDER BY a.agent_id;

-- ---------------------------------------------------------------------
-- Transactions (explicit ids for readability)
-- ---------------------------------------------------------------------
INSERT INTO txn (txn_id, txn_type, source_wallet_id, dest_wallet_id, amount, currency_code, channel, status, reversal_of, failure_reason, created_at, completed_at)
SELECT id, t, s, d, amt, cur, ch, st, rev, why,
       TIMESTAMPTZ '2026-10-01 08:00+01' + id * INTERVAL '7 hours',
       CASE WHEN st = 'PENDING' THEN NULL
            ELSE TIMESTAMPTZ '2026-10-01 08:00+01' + id * INTERVAL '7 hours' + INTERVAL '4 seconds' END
FROM (VALUES
 ( 1,'CASH_IN', NULL::bigint,11::bigint,2000000.00,'NGN','API',  'SUCCESS', NULL::bigint,NULL),  -- agent float funding
 ( 2,'CASH_IN', NULL,       12,  1500000.00,'NGN','API',  'SUCCESS', NULL,NULL),
 ( 3,'CASH_IN', NULL,       13,    50000.00,'GHS','API',  'SUCCESS', NULL,NULL),
 ( 4,'CASH_IN', 11,          1,    50000.00,'NGN','AGENT','SUCCESS', NULL,NULL),
 ( 5,'CASH_IN', 11,          2,   120000.00,'NGN','AGENT','SUCCESS', NULL,NULL),
 ( 6,'CASH_IN', 12,          3,    30000.00,'NGN','AGENT','SUCCESS', NULL,NULL),
 ( 7,'CASH_IN', 12,          4,    75000.00,'NGN','AGENT','SUCCESS', NULL,NULL),
 ( 8,'CASH_IN', 11,          5,   200000.00,'NGN','AGENT','SUCCESS', NULL,NULL),
 ( 9,'CASH_IN', 13,          8,     1500.00,'GHS','AGENT','SUCCESS', NULL,NULL),
 (10,'CASH_IN', 13,          9,      800.00,'GHS','AGENT','SUCCESS', NULL,NULL),
 (11,'P2P',      1,          2,    10000.00,'NGN','USSD', 'SUCCESS', NULL,NULL),
 (12,'P2P',      2,          3,     5000.00,'NGN','APP',  'SUCCESS', NULL,NULL),
 (13,'P2P',      5,          6,    25000.00,'NGN','APP',  'SUCCESS', NULL,NULL),
 (14,'BILL_PAY', 4,       NULL,     8500.00,'NGN','USSD', 'SUCCESS', NULL,NULL),
 (15,'BILL_PAY', 1,       NULL,     1000.00,'NGN','USSD', 'SUCCESS', NULL,NULL),
 (16,'CASH_OUT', 3,         12,    10000.00,'NGN','AGENT','SUCCESS', NULL,NULL),
 (17,'P2P',      6,          7,     2000.00,'NGN','APP',  'FAILED',  NULL,'Recipient wallet frozen'),
 (18,'P2P',      1,          4,     3000.00,'NGN','USSD', 'REVERSED',NULL,NULL),
 (19,'REVERSAL', 4,          1,     3000.00,'NGN','API',  'SUCCESS', 18,  NULL),  -- sent in error
 (20,'P2P',      8,          9,      200.00,'GHS','APP',  'SUCCESS', NULL,NULL),
 (21,'P2P',      5,          2,    15000.00,'NGN','API',  'PENDING', NULL,NULL),
 (22,'BILL_PAY', 2,       NULL,    12000.00,'NGN','APP',  'SUCCESS', NULL,NULL)
) AS v(id,t,s,d,amt,cur,ch,st,rev,why);

SELECT setval(pg_get_serial_sequence('kashlink.txn','txn_id'), (SELECT max(txn_id) FROM txn));

INSERT INTO bill_payment VALUES
 (14, 1, 'METER-45120987'),
 (15, 3, '2348031110001'),
 (22, 2, 'SMARTCARD-7741002');

-- ---------------------------------------------------------------------
-- Ledger: one debit (source) and one credit (destination) per posted txn.
-- balance_after is a running total per wallet, computed with a window function.
-- ---------------------------------------------------------------------
INSERT INTO ledger_entry (txn_id, wallet_id, direction, amount, balance_after, posted_at)
WITH movements AS (
    SELECT txn_id, source_wallet_id AS wallet_id, 'D' AS direction, amount, -amount AS delta, completed_at
    FROM txn WHERE status IN ('SUCCESS','REVERSED') AND source_wallet_id IS NOT NULL
    UNION ALL
    SELECT txn_id, dest_wallet_id, 'C', amount, amount, completed_at
    FROM txn WHERE status IN ('SUCCESS','REVERSED') AND dest_wallet_id IS NOT NULL
)
SELECT txn_id, wallet_id, direction, amount,
       SUM(delta) OVER (PARTITION BY wallet_id ORDER BY txn_id, direction
                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
       completed_at
FROM movements
ORDER BY txn_id, direction DESC;

-- Cached balance = sum of ledger movements
UPDATE wallet w
SET balance = COALESCE(l.net, 0)
FROM (SELECT wallet_id,
             SUM(CASE direction WHEN 'C' THEN amount ELSE -amount END) AS net
      FROM ledger_entry GROUP BY wallet_id) l
WHERE w.wallet_id = l.wallet_id;
