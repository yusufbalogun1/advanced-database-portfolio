-- =====================================================================
-- Portfolio 2 - Bulk data generator for KashLink Mobile Money
-- Adds ~50,000 customers, 1,000 agents and ~550,000 transactions
-- (plus ~1 million ledger entries) on top of the Portfolio 1 seed data.
-- Run AFTER portfolio-1 scripts 01_schema.sql and 02_seed.sql.
-- Takes roughly 1-2 minutes.
-- =====================================================================
SET search_path TO kashlink;
\timing on

SELECT setseed(0.42);   -- same "random" data on every run (reproducible)

-- Uganda needs billers for bill payments
INSERT INTO biller (biller_name, category, country_code) VALUES
 ('Kampala Power',       'ELECTRICITY','UG'),
 ('KashLink Airtime UG', 'AIRTIME',    'UG')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- 1. Customers: 35,000 NG, 10,000 GH, 5,000 UG
-- ---------------------------------------------------------------------
INSERT INTO customer (msisdn, first_name, last_name, date_of_birth, country_code, tier_level, created_at)
SELECT
    CASE cc WHEN 'NG' THEN '2349' || lpad(g::text, 9, '0')
            WHEN 'GH' THEN '2335' || lpad(g::text, 8, '0')
            ELSE           '2567' || lpad(g::text, 8, '0') END,
    (CASE cc WHEN 'NG' THEN ARRAY['Chinedu','Aisha','Tobi','Ngozi','Yusuf','Kemi','Emeka','Fatima','Seun','Uche','Halima','Bayo','Ifeoma','Musa','Folake','Obinna','Zainab','Tunde','Amaka','Sani']
             WHEN 'GH' THEN ARRAY['Kwame','Ama','Kofi','Akosua','Yaw','Abena','Kwesi','Efua','Kojo','Adwoa','Fiifi','Esi']
             ELSE           ARRAY['Grace','Joseph','Sarah','Moses','Esther','Brian','Ruth','Isaac','Joan','Daniel'] END)
        [1 + floor(random() * CASE cc WHEN 'NG' THEN 20 WHEN 'GH' THEN 12 ELSE 10 END)::int],
    (CASE cc WHEN 'NG' THEN ARRAY['Okafor','Bello','Adeyemi','Okeke','Musa','Balogun','Eze','Ibrahim','Nwosu','Lawal','Obi','Ogunleye','Abubakar','Chukwu','Adebayo','Umar','Nnamdi','Olawale','Danjuma','Ekwueme','Salami','Afolabi','Garba','Oyelaran','Agu']
             WHEN 'GH' THEN ARRAY['Mensah','Owusu','Asante','Boateng','Osei','Agyeman','Appiah','Darko','Ofori','Addo','Quaye','Tetteh']
             ELSE           ARRAY['Namutebi','Okello','Mugisha','Nakato','Ssempa','Atim','Kato','Nabirye','Opio','Tumusiime'] END)
        [1 + floor(random() * CASE cc WHEN 'NG' THEN 25 WHEN 'GH' THEN 12 ELSE 10 END)::int],
    DATE '1960-01-01' + (random() * 14000)::int,
    cc,
    CASE WHEN random() < 0.60 THEN 1 WHEN random() < 0.85 THEN 2 ELSE 3 END,
    TIMESTAMPTZ '2025-06-01 00:00+01' + random() * INTERVAL '200 days'
FROM (SELECT g, CASE WHEN g <= 35000 THEN 'NG' WHEN g <= 45000 THEN 'GH' ELSE 'UG' END AS cc
      FROM generate_series(1, 50000) g) s;

-- ---------------------------------------------------------------------
-- 2. Agents: 700 NG, 200 GH, 100 UG
-- ---------------------------------------------------------------------
INSERT INTO agent (agent_code, business_name, msisdn, country_code, city, onboarded_at)
SELECT cc || '-AG-' || lpad(g::text, 4, '0'),
       'Agent Shop ' || g,
       CASE cc WHEN 'NG' THEN '2347' || lpad(g::text, 9, '0')
               WHEN 'GH' THEN '2332' || lpad(g::text, 8, '0')
               ELSE           '2560' || lpad(g::text, 8, '0') END,
       cc,
       (CASE cc WHEN 'NG' THEN ARRAY['Lagos','Abuja','Kano','Ibadan','Port Harcourt','Enugu']
                WHEN 'GH' THEN ARRAY['Accra','Kumasi','Tamale','Takoradi']
                ELSE           ARRAY['Kampala','Gulu','Mbarara','Jinja'] END)
           [1 + floor(random() * CASE cc WHEN 'NG' THEN 6 ELSE 4 END)::int],
       TIMESTAMPTZ '2025-01-01 00:00+01' + random() * INTERVAL '300 days'
FROM (SELECT g, CASE WHEN g <= 700 THEN 'NG' WHEN g <= 900 THEN 'GH' ELSE 'UG' END AS cc
      FROM generate_series(1, 1000) g) s;

-- ---------------------------------------------------------------------
-- 3. Wallets for the new customers and agents
-- ---------------------------------------------------------------------
INSERT INTO wallet (customer_id, currency_code, opened_at)
SELECT c.customer_id, co.currency_code, c.created_at
FROM customer c JOIN country co USING (country_code)
WHERE c.customer_id > 10;

INSERT INTO wallet (agent_id, currency_code, opened_at)
SELECT a.agent_id, co.currency_code, a.onboarded_at
FROM agent a JOIN country co USING (country_code)
WHERE a.agent_id > 3;

-- Lookup pools: numbered wallets per country, used to pick random parties
CREATE TEMP TABLE pool_cust  AS
SELECT c.country_code AS cc, row_number() OVER (PARTITION BY c.country_code ORDER BY w.wallet_id) AS rn, w.wallet_id
FROM wallet w JOIN customer c ON c.customer_id = w.customer_id WHERE c.customer_id > 10;
CREATE TEMP TABLE pool_agent AS
SELECT a.country_code AS cc, row_number() OVER (PARTITION BY a.country_code ORDER BY w.wallet_id) AS rn, w.wallet_id
FROM wallet w JOIN agent a ON a.agent_id = w.agent_id WHERE a.agent_id > 3;
CREATE TEMP TABLE pool_biller AS
SELECT country_code AS cc, row_number() OVER (PARTITION BY country_code ORDER BY biller_id) AS rn, biller_id
FROM biller;
CREATE TEMP TABLE pool_size AS
SELECT co.country_code AS cc, co.currency_code,
       (SELECT count(*) FROM pool_cust   p WHERE p.cc = co.country_code) AS n_cust,
       (SELECT count(*) FROM pool_agent  p WHERE p.cc = co.country_code) AS n_agent,
       (SELECT count(*) FROM pool_biller p WHERE p.cc = co.country_code) AS n_biller
FROM country co;
CREATE INDEX ON pool_cust (cc, rn);
CREATE INDEX ON pool_agent (cc, rn);
CREATE INDEX ON pool_biller (cc, rn);

-- ---------------------------------------------------------------------
-- 4. Opening balances: every new wallet is funded on 1 Jan 2026
-- ---------------------------------------------------------------------
INSERT INTO txn (txn_type, source_wallet_id, dest_wallet_id, amount, currency_code, channel, status, created_at, completed_at)
SELECT 'CASH_IN', NULL, w.wallet_id,
       CASE WHEN w.agent_id IS NOT NULL THEN 50000000 ELSE 500000 END,
       w.currency_code, 'API', 'SUCCESS',
       TIMESTAMPTZ '2026-01-01 00:00+01', TIMESTAMPTZ '2026-01-01 00:00:03+01'
FROM wallet w WHERE w.wallet_id > 13
ORDER BY w.wallet_id;

-- ---------------------------------------------------------------------
-- 5. 500,000 transactions spread from 2 Jan to 31 Oct 2026
--    Mix: 55% P2P, 20% bill pay, 15% cash-out, 10% cash-in
--    Status: 93% success, 5% failed, 2% pending
-- ---------------------------------------------------------------------
INSERT INTO txn (txn_type, source_wallet_id, dest_wallet_id, amount, currency_code, channel, status,
                 failure_reason, created_at, completed_at)
SELECT r.txn_type,
       CASE r.txn_type WHEN 'CASH_IN' THEN pa.wallet_id ELSE ps.wallet_id END,
       CASE r.txn_type WHEN 'P2P'      THEN pd.wallet_id
                       WHEN 'BILL_PAY' THEN NULL
                       WHEN 'CASH_OUT' THEN pa.wallet_id
                       ELSE ps.wallet_id END,
       round((100 + r.r_amt * 9900)::numeric, 2),
       r.currency_code,
       CASE WHEN r.txn_type IN ('CASH_IN','CASH_OUT') THEN 'AGENT'
            WHEN r.r_ch < 0.45 THEN 'USSD' WHEN r.r_ch < 0.90 THEN 'APP' ELSE 'API' END,
       r.status,
       CASE WHEN r.status = 'FAILED'
            THEN (ARRAY['Insufficient funds','Daily limit exceeded','Wrong PIN','Network timeout','Recipient wallet frozen'])
                 [1 + floor(r.r_ch * 5)::int] END,
       r.created_at,
       CASE WHEN r.status = 'PENDING' THEN NULL ELSE r.created_at + INTERVAL '3 seconds' END
FROM (
    SELECT g, ps_.cc, ps_.currency_code,
           CASE WHEN t < 0.55 THEN 'P2P' WHEN t < 0.75 THEN 'BILL_PAY'
                WHEN t < 0.90 THEN 'CASH_OUT' ELSE 'CASH_IN' END AS txn_type,
           CASE WHEN s < 0.93 THEN 'SUCCESS' WHEN s < 0.98 THEN 'FAILED' ELSE 'PENDING' END AS status,
           1 + floor(r1 * ps_.n_cust)::int AS src_rn,
           1 + ((floor(r1 * ps_.n_cust)::int + 1 + floor(r2 * (ps_.n_cust - 1))::int) % ps_.n_cust::int) AS dst_rn,
           1 + floor(r2 * ps_.n_agent)::int AS agent_rn,
           r_amt, r_ch,
           TIMESTAMPTZ '2026-01-02 00:00+01' + g * (INTERVAL '302 days' / 500000) AS created_at
    FROM (SELECT g, random() AS rc, random() AS t, random() AS s, random() AS r1, random() AS r2,
                 random() AS r_amt, random() AS r_ch
          FROM generate_series(1, 500000) g) x
    JOIN pool_size ps_ ON ps_.cc = CASE WHEN x.rc < 0.70 THEN 'NG' WHEN x.rc < 0.90 THEN 'GH' ELSE 'UG' END
) r
JOIN pool_cust  ps ON ps.cc = r.cc AND ps.rn = r.src_rn
JOIN pool_cust  pd ON pd.cc = r.cc AND pd.rn = r.dst_rn
JOIN pool_agent pa ON pa.cc = r.cc AND pa.rn = r.agent_rn
ORDER BY r.g;

-- Bill payment details for the generated bill payments
INSERT INTO bill_payment (txn_id, biller_id, customer_reference)
SELECT t.txn_id, pb.biller_id, 'REF-' || t.txn_id
FROM txn t
JOIN wallet w     ON w.wallet_id = t.source_wallet_id
JOIN customer c   ON c.customer_id = w.customer_id
JOIN pool_size ps ON ps.cc = c.country_code
JOIN pool_biller pb ON pb.cc = c.country_code AND pb.rn = 1 + (t.txn_id % ps.n_biller)
WHERE t.txn_type = 'BILL_PAY' AND t.txn_id > 22;

-- ---------------------------------------------------------------------
-- 6. Ledger entries for successful generated transactions + balances
-- ---------------------------------------------------------------------
INSERT INTO ledger_entry (txn_id, wallet_id, direction, amount, balance_after, posted_at)
WITH movements AS (
    SELECT txn_id, source_wallet_id AS wallet_id, 'D' AS direction, amount, -amount AS delta, completed_at
    FROM txn WHERE txn_id > 22 AND status = 'SUCCESS' AND source_wallet_id IS NOT NULL
    UNION ALL
    SELECT txn_id, dest_wallet_id, 'C', amount, amount, completed_at
    FROM txn WHERE txn_id > 22 AND status = 'SUCCESS' AND dest_wallet_id IS NOT NULL
)
SELECT txn_id, wallet_id, direction, amount,
       SUM(delta) OVER (PARTITION BY wallet_id ORDER BY txn_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
       completed_at
FROM movements;

UPDATE wallet w SET balance = l.net
FROM (SELECT wallet_id, SUM(CASE direction WHEN 'C' THEN amount ELSE -amount END) AS net
      FROM ledger_entry WHERE txn_id > 22 GROUP BY wallet_id) l
WHERE w.wallet_id = l.wallet_id AND w.wallet_id > 13;

VACUUM ANALYZE;

-- Summary
SELECT 'customer' AS tbl, count(*) FROM customer UNION ALL
SELECT 'agent', count(*) FROM agent UNION ALL
SELECT 'wallet', count(*) FROM wallet UNION ALL
SELECT 'txn', count(*) FROM txn UNION ALL
SELECT 'ledger_entry', count(*) FROM ledger_entry UNION ALL
SELECT 'bill_payment', count(*) FROM bill_payment;
