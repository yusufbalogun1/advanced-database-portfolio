-- =====================================================================
-- Portfolio 3 - Setup: demo wallets, safe transfer function, reset helper
-- Run once (safe to re-run). Requires Portfolio 1 schema + seed.
-- =====================================================================
SET search_path TO kashlink;

-- ---------------------------------------------------------------------
-- 1. Four dedicated demo customers (Tier 3), so the experiments never
--    touch the Portfolio 1/2 data.
-- ---------------------------------------------------------------------
INSERT INTO customer (msisdn, first_name, last_name, date_of_birth, country_code, tier_level) VALUES
 ('2348000000001','Ada',  'Demo','1990-01-01','NG',3),
 ('2348000000002','Bola', 'Demo','1990-01-01','NG',3),
 ('2348000000003','Chidi','Demo','1990-01-01','NG',3),
 ('2348000000004','Dayo', 'Demo','1990-01-01','NG',3)
ON CONFLICT (msisdn) DO NOTHING;

INSERT INTO wallet (customer_id, currency_code)
SELECT customer_id, 'NGN' FROM customer WHERE msisdn LIKE '234800000000_'
ON CONFLICT DO NOTHING;

-- Convenience view used by every demo
CREATE OR REPLACE VIEW demo_wallets AS
SELECT c.first_name AS name, c.msisdn, w.wallet_id, w.balance, w.version, w.status
FROM wallet w JOIN customer c ON c.customer_id = w.customer_id
WHERE c.msisdn LIKE '234800000000_'
ORDER BY c.msisdn;

-- ---------------------------------------------------------------------
-- 2. p2p_transfer: the SAFE way to move money.
--    * Runs inside the caller's transaction, so it is all-or-nothing.
--    * Locks BOTH wallets with SELECT ... FOR UPDATE (pessimistic locking)
--      in ascending wallet_id order, so two opposite transfers can never
--      deadlock each other.
--    * Re-checks balance AFTER taking the lock, so it always sees the latest committed value.
--    * Idempotent: the same txn_ref can only ever post once.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION p2p_transfer(
    p_from_msisdn VARCHAR,
    p_to_msisdn   VARCHAR,
    p_amount      NUMERIC,
    p_channel     VARCHAR DEFAULT 'APP',
    p_ref         UUID    DEFAULT gen_random_uuid()
) RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = kashlink
AS $$
DECLARE
    v_src      wallet%ROWTYPE;
    v_dst      wallet%ROWTYPE;
    v_src_id   BIGINT;
    v_dst_id   BIGINT;
    v_limit    NUMERIC;
    v_today    NUMERIC;
    v_txn_id   BIGINT;
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive' USING ERRCODE = 'check_violation';
    END IF;

    -- Idempotency: a retried request with the same reference returns the original result
    SELECT txn_id INTO v_txn_id FROM txn WHERE txn_ref = p_ref;
    IF FOUND THEN
        RAISE NOTICE 'Duplicate request %: returning existing txn %', p_ref, v_txn_id;
        RETURN v_txn_id;
    END IF;

    SELECT w.wallet_id INTO v_src_id FROM wallet w JOIN customer c USING (customer_id) WHERE c.msisdn = p_from_msisdn;
    SELECT w.wallet_id INTO v_dst_id FROM wallet w JOIN customer c USING (customer_id) WHERE c.msisdn = p_to_msisdn;
    IF v_src_id IS NULL OR v_dst_id IS NULL THEN
        RAISE EXCEPTION 'Unknown sender or recipient';
    END IF;

    -- Lock both rows in a fixed global order (lowest wallet_id first) to prevent deadlocks
    PERFORM 1 FROM wallet WHERE wallet_id IN (v_src_id, v_dst_id) ORDER BY wallet_id FOR UPDATE;

    SELECT * INTO v_src FROM wallet WHERE wallet_id = v_src_id;
    SELECT * INTO v_dst FROM wallet WHERE wallet_id = v_dst_id;

    IF v_src.status <> 'ACTIVE' THEN RAISE EXCEPTION 'Sender wallet % is %', v_src_id, v_src.status; END IF;
    IF v_dst.status <> 'ACTIVE' THEN RAISE EXCEPTION 'Recipient wallet % is %', v_dst_id, v_dst.status; END IF;
    IF v_src.currency_code <> v_dst.currency_code THEN RAISE EXCEPTION 'Currency mismatch'; END IF;
    IF v_src.balance < p_amount THEN
        RAISE EXCEPTION 'Insufficient funds: balance %, requested %', v_src.balance, p_amount;
    END IF;

    -- KYC tier daily limit
    SELECT t.daily_txn_limit INTO v_limit
    FROM customer c JOIN kyc_tier t USING (tier_level) WHERE c.customer_id = v_src.customer_id;
    SELECT COALESCE(SUM(amount), 0) INTO v_today
    FROM ledger_entry WHERE wallet_id = v_src_id AND direction = 'D' AND posted_at >= date_trunc('day', now());
    IF v_today + p_amount > v_limit THEN
        RAISE EXCEPTION 'Daily limit exceeded: used %, limit %', v_today, v_limit;
    END IF;

    -- All checks passed: write everything
    INSERT INTO txn (txn_ref, txn_type, source_wallet_id, dest_wallet_id, amount, currency_code, channel, status, completed_at)
    VALUES (p_ref, 'P2P', v_src_id, v_dst_id, p_amount, v_src.currency_code, p_channel, 'SUCCESS', clock_timestamp())
    RETURNING txn_id INTO v_txn_id;

    UPDATE wallet SET balance = balance - p_amount, version = version + 1 WHERE wallet_id = v_src_id;
    UPDATE wallet SET balance = balance + p_amount, version = version + 1 WHERE wallet_id = v_dst_id;

    INSERT INTO ledger_entry (txn_id, wallet_id, direction, amount, balance_after, posted_at) VALUES
        (v_txn_id, v_src_id, 'D', p_amount, v_src.balance - p_amount, clock_timestamp()),
        (v_txn_id, v_dst_id, 'C', p_amount, v_dst.balance + p_amount, clock_timestamp());

    RETURN v_txn_id;
END $$;

-- ---------------------------------------------------------------------
-- 3. demo_reset(): put the four demo wallets back to NGN 1,000,000 each,
--    with a matching opening ledger entry, so every experiment starts clean.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION demo_reset() RETURNS VOID
LANGUAGE plpgsql SET search_path = kashlink AS $$
DECLARE
    w RECORD; v_txn BIGINT;
BEGIN
    DELETE FROM ledger_entry WHERE wallet_id IN (SELECT wallet_id FROM demo_wallets);
    DELETE FROM ledger_entry WHERE txn_id IN (SELECT txn_id FROM txn
        WHERE source_wallet_id IN (SELECT wallet_id FROM demo_wallets)
           OR dest_wallet_id   IN (SELECT wallet_id FROM demo_wallets));
    DELETE FROM txn WHERE source_wallet_id IN (SELECT wallet_id FROM demo_wallets)
                       OR dest_wallet_id   IN (SELECT wallet_id FROM demo_wallets);
    FOR w IN SELECT wallet_id FROM demo_wallets LOOP
        INSERT INTO txn (txn_type, dest_wallet_id, amount, currency_code, channel, status, completed_at)
        VALUES ('CASH_IN', w.wallet_id, 1000000, 'NGN', 'API', 'SUCCESS', now()) RETURNING txn_id INTO v_txn;
        INSERT INTO ledger_entry (txn_id, wallet_id, direction, amount, balance_after)
        VALUES (v_txn, w.wallet_id, 'C', 1000000, 1000000);
        UPDATE wallet SET balance = 1000000, version = 0, status = 'ACTIVE' WHERE wallet_id = w.wallet_id;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 4. Reconciliation check for the demo wallets (expect 0 rows)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW demo_reconciliation AS
SELECT d.name, d.wallet_id, d.balance AS cached_balance,
       COALESCE(SUM(CASE l.direction WHEN 'C' THEN l.amount ELSE -l.amount END), 0) AS ledger_balance
FROM demo_wallets d LEFT JOIN ledger_entry l USING (wallet_id)
GROUP BY d.name, d.wallet_id, d.balance
HAVING d.balance <> COALESCE(SUM(CASE l.direction WHEN 'C' THEN l.amount ELSE -l.amount END), 0);

SELECT demo_reset();
SELECT * FROM demo_wallets;
