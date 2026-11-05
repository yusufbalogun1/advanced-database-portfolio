-- =====================================================================
-- KashLink Mobile Money (simulated) - Relational Schema
-- MIT 8103 Advanced Database Systems - Portfolio 1
-- Target DBMS: PostgreSQL 16
-- Run: psql -U postgres -d kashlink -f 01_schema.sql
-- =====================================================================

DROP SCHEMA IF EXISTS kashlink CASCADE;
CREATE SCHEMA kashlink;
SET search_path TO kashlink;

-- ---------------------------------------------------------------------
-- 1. Reference / lookup tables
-- ---------------------------------------------------------------------

-- Countries (operating markets). Natural key: ISO 3166-1 alpha-2 code.
CREATE TABLE country (
    country_code   CHAR(2)      PRIMARY KEY,
    country_name   VARCHAR(60)  NOT NULL UNIQUE,
    currency_code  CHAR(3)      NOT NULL,              -- ISO 4217, e.g. NGN, GHS
    dial_prefix    VARCHAR(4)   NOT NULL UNIQUE        -- e.g. 234
);

-- KYC tier rules. Limits depend on the tier, not on the customer,
-- so they live here (3NF) instead of being repeated on every customer row.
CREATE TABLE kyc_tier (
    tier_level       SMALLINT      PRIMARY KEY CHECK (tier_level BETWEEN 1 AND 3),
    tier_name        VARCHAR(30)   NOT NULL UNIQUE,
    max_balance      NUMERIC(18,2) NOT NULL CHECK (max_balance > 0),
    daily_txn_limit  NUMERIC(18,2) NOT NULL CHECK (daily_txn_limit > 0)
);

-- Back-office staff who verify KYC documents.
CREATE TABLE staff (
    staff_id    SERIAL       PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL,
    email       VARCHAR(120) NOT NULL UNIQUE,
    staff_role  VARCHAR(20)  NOT NULL
                CHECK (staff_role IN ('KYC_OFFICER','SUPPORT','FINANCE','ADMIN')),
    country_code CHAR(2)     NOT NULL REFERENCES country(country_code)
);

-- Billers (utilities, TV, airtime) that customers can pay.
CREATE TABLE biller (
    biller_id      SERIAL       PRIMARY KEY,
    biller_name    VARCHAR(100) NOT NULL,
    category       VARCHAR(20)  NOT NULL
                   CHECK (category IN ('AIRTIME','DATA','ELECTRICITY','TV','WATER','EDUCATION')),
    country_code   CHAR(2)      NOT NULL REFERENCES country(country_code),
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    UNIQUE (biller_name, country_code)
);

-- ---------------------------------------------------------------------
-- 2. Core parties
-- ---------------------------------------------------------------------

CREATE TABLE customer (
    customer_id    BIGSERIAL    PRIMARY KEY,                 -- surrogate key
    msisdn         VARCHAR(15)  NOT NULL UNIQUE              -- candidate key (phone number)
                   CHECK (msisdn ~ '^[0-9]{10,15}$'),
    first_name     VARCHAR(50)  NOT NULL,
    last_name      VARCHAR(50)  NOT NULL,
    date_of_birth  DATE         NOT NULL
                   CHECK (date_of_birth <= CURRENT_DATE - INTERVAL '18 years'),
    email          VARCHAR(120) UNIQUE,
    country_code   CHAR(2)      NOT NULL REFERENCES country(country_code),
    tier_level     SMALLINT     NOT NULL DEFAULT 1 REFERENCES kyc_tier(tier_level),
    status         VARCHAR(10)  NOT NULL DEFAULT 'ACTIVE'
                   CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE kyc_document (
    document_id    BIGSERIAL    PRIMARY KEY,
    customer_id    BIGINT       NOT NULL REFERENCES customer(customer_id) ON DELETE CASCADE,
    document_type  VARCHAR(20)  NOT NULL
                   CHECK (document_type IN ('NATIONAL_ID','PASSPORT','DRIVERS_LICENCE','VOTERS_CARD','UTILITY_BILL')),
    document_ref   VARCHAR(40)  NOT NULL,
    submitted_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    verified_by    INT          REFERENCES staff(staff_id),
    verified_at    TIMESTAMPTZ,
    UNIQUE (document_type, document_ref),
    -- A document is either unverified (both NULL) or fully verified (both set)
    CONSTRAINT chk_kyc_verified_pair CHECK ((verified_by IS NULL) = (verified_at IS NULL)),
    CONSTRAINT chk_kyc_verified_after CHECK (verified_at IS NULL OR verified_at >= submitted_at)
);

-- Agents run kiosks where customers deposit (cash-in) and withdraw (cash-out).
CREATE TABLE agent (
    agent_id       BIGSERIAL    PRIMARY KEY,
    agent_code     VARCHAR(10)  NOT NULL UNIQUE,             -- business-facing code
    business_name  VARCHAR(100) NOT NULL,
    msisdn         VARCHAR(15)  NOT NULL UNIQUE CHECK (msisdn ~ '^[0-9]{10,15}$'),
    country_code   CHAR(2)      NOT NULL REFERENCES country(country_code),
    city           VARCHAR(50)  NOT NULL,
    status         VARCHAR(10)  NOT NULL DEFAULT 'ACTIVE'
                   CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
    onboarded_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 3. Wallets: owned by EXACTLY ONE customer OR one agent
-- ---------------------------------------------------------------------
CREATE TABLE wallet (
    wallet_id      BIGSERIAL     PRIMARY KEY,
    customer_id    BIGINT        REFERENCES customer(customer_id),
    agent_id       BIGINT        REFERENCES agent(agent_id),
    currency_code  CHAR(3)       NOT NULL,
    balance        NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (balance >= 0),  -- no overdrafts
    status         VARCHAR(10)   NOT NULL DEFAULT 'ACTIVE'
                   CHECK (status IN ('ACTIVE','FROZEN','CLOSED')),
    version        INT           NOT NULL DEFAULT 0,   -- used for optimistic locking (Portfolio 3)
    opened_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    -- exclusive-arc constraint: exactly one owner
    CONSTRAINT wallet_single_owner CHECK (num_nonnulls(customer_id, agent_id) = 1),
    -- one wallet per owner per currency
    CONSTRAINT uq_customer_currency UNIQUE (customer_id, currency_code),
    CONSTRAINT uq_agent_currency    UNIQUE (agent_id, currency_code)
);

-- ---------------------------------------------------------------------
-- 4. Transactions (business event) + ledger entries (double-entry)
-- ---------------------------------------------------------------------
CREATE TABLE txn (
    txn_id           BIGSERIAL     PRIMARY KEY,
    txn_ref          UUID          NOT NULL UNIQUE DEFAULT gen_random_uuid(), -- idempotency key
    txn_type         VARCHAR(12)   NOT NULL
                     CHECK (txn_type IN ('P2P','CASH_IN','CASH_OUT','BILL_PAY','REVERSAL')),
    source_wallet_id BIGINT        REFERENCES wallet(wallet_id),
    dest_wallet_id   BIGINT        REFERENCES wallet(wallet_id),
    amount           NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    fee              NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (fee >= 0),
    currency_code    CHAR(3)       NOT NULL,
    channel          VARCHAR(6)    NOT NULL CHECK (channel IN ('USSD','APP','AGENT','API')),
    status           VARCHAR(10)   NOT NULL DEFAULT 'PENDING'
                     CHECK (status IN ('PENDING','SUCCESS','FAILED','REVERSED')),
    reversal_of      BIGINT        REFERENCES txn(txn_id),    -- recursive (unary) relationship
    failure_reason   VARCHAR(100),
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    completed_at     TIMESTAMPTZ,
    CONSTRAINT chk_txn_not_self CHECK (source_wallet_id IS DISTINCT FROM dest_wallet_id),
    CONSTRAINT chk_txn_completed_after CHECK (completed_at IS NULL OR completed_at >= created_at),
    -- every type needs at least one side
    CONSTRAINT chk_txn_has_party CHECK (num_nonnulls(source_wallet_id, dest_wallet_id) >= 1),
    -- only reversals point at another transaction
    CONSTRAINT chk_txn_reversal_link CHECK ((txn_type = 'REVERSAL') = (reversal_of IS NOT NULL)),
    -- failed transactions must say why
    CONSTRAINT chk_txn_failure_reason CHECK (status <> 'FAILED' OR failure_reason IS NOT NULL)
);

-- Double-entry ledger: each successful txn produces a debit and a credit.
CREATE TABLE ledger_entry (
    entry_id       BIGSERIAL     PRIMARY KEY,
    txn_id         BIGINT        NOT NULL REFERENCES txn(txn_id),
    wallet_id      BIGINT        NOT NULL REFERENCES wallet(wallet_id),
    direction      CHAR(1)       NOT NULL CHECK (direction IN ('D','C')),  -- Debit / Credit
    amount         NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    balance_after  NUMERIC(18,2) NOT NULL CHECK (balance_after >= 0),
    posted_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    UNIQUE (txn_id, wallet_id, direction)
);

-- Extra detail that only applies to BILL_PAY transactions (1:1 subtype of txn).
CREATE TABLE bill_payment (
    txn_id              BIGINT       PRIMARY KEY REFERENCES txn(txn_id),
    biller_id           INT          NOT NULL REFERENCES biller(biller_id),
    customer_reference  VARCHAR(40)  NOT NULL   -- meter no., smartcard no., phone no.
);

-- ---------------------------------------------------------------------
-- 5. Indexes on foreign keys (PostgreSQL does not create these automatically)
--    Query-specific indexes are added and measured in Portfolio 2.
-- ---------------------------------------------------------------------
CREATE INDEX idx_customer_country   ON customer(country_code);
CREATE INDEX idx_kyc_customer       ON kyc_document(customer_id);
CREATE INDEX idx_ledger_txn         ON ledger_entry(txn_id);
CREATE INDEX idx_bill_biller        ON bill_payment(biller_id);

COMMENT ON TABLE txn IS 'Business transaction event; named txn because TRANSACTION is an SQL keyword';
COMMENT ON COLUMN wallet.balance IS 'Controlled redundancy: cached sum of ledger entries, reconciled by audit query';
