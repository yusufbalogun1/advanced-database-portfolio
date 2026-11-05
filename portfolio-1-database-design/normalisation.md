# Normalisation: from a flat agent report to 3NF/BCNF

## Starting point: the unnormalised record (UNF)

Before the system was designed, assume each agent kept a daily spreadsheet like this:

| TxnRef | Date | AgentCode | AgentName | AgentCity | CustomerPhone | CustomerName | Tier | TierDailyLimit | Country | Currency | IDDocuments | Type | Amount | BillerName | BillerCategory |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| T-0004 | 01-Oct | NG-LAG-001 | Mama Tee Ventures | Lagos | 2348031110001 | Chioma Okeke | 2 | 200,000 | Nigeria | NGN | NIN-00000001 | CASH_IN | 50,000 | | |
| T-0008 | 03-Oct | NG-LAG-001 | Mama Tee Ventures | Lagos | 2348031110005 | Zainab Bello | 3 | 2,000,000 | Nigeria | NGN | A00000005; LPD-778812 | CASH_IN | 200,000 | | |
| T-0015 | 05-Oct | | | | 2348031110001 | Chioma Okeke | 2 | 200,000 | Nigeria | NGN | NIN-00000001 | BILL_PAY | 1,000 | KashLink Airtime NG | AIRTIME |

Problems with this layout:

- **Update anomaly:** if Chioma moves from Tier 2 to Tier 3, every row she appears in must be edited. Miss one and the data contradicts itself.
- **Insertion anomaly:** a new agent cannot be recorded until it performs its first transaction.
- **Deletion anomaly:** deleting the only transaction for an agent also deletes the only record that the agent exists.
- **Multi-valued cell:** `IDDocuments` holds a list ("A00000005; LPD-778812").

## Functional dependencies identified

```
TxnRef        -> Date, AgentCode, CustomerPhone, Type, Amount, BillerName
AgentCode     -> AgentName, AgentCity, Country
CustomerPhone -> CustomerName, Tier, Country
Tier          -> TierDailyLimit, TierMaxBalance
Country       -> Currency
BillerName, Country -> BillerCategory
DocumentType, DocumentRef -> CustomerPhone
```

## 1NF: atomic values, no repeating groups

`IDDocuments` is split out into a separate relation with one row per document:

- `TXN_REPORT(TxnRef, Date, AgentCode, AgentName, ..., Amount, BillerName, BillerCategory)`
- `KYC_DOCUMENT(DocumentType, DocumentRef, CustomerPhone, VerifiedBy, VerifiedAt)`

Every cell now holds a single value and every row is uniquely identified (`TxnRef`, and `DocumentType + DocumentRef`).

## 2NF: remove partial dependencies

2NF only matters where a key is composite. In `KYC_DOCUMENT` the key is `(DocumentType, DocumentRef)`. If the customer's name were stored there, it would depend on `CustomerPhone`, not on the full key. So customer attributes stay out of the document table and only the foreign key `customer_id` remains.

The same reasoning applies to `ledger_entry`, whose natural key is `(txn_id, wallet_id, direction)`. Only attributes that depend on the whole entry (amount, balance_after, posted_at) are kept there. The transaction's channel and type stay in `txn`.

## 3NF: remove transitive dependencies

`TXN_REPORT` still contains chains such as `TxnRef -> CustomerPhone -> Tier -> TierDailyLimit`. Each determinant becomes its own relation:

| Transitive chain removed | New relation |
|---|---|
| TxnRef -> AgentCode -> AgentName, City | `agent` |
| TxnRef -> CustomerPhone -> Name, Tier | `customer` |
| CustomerPhone -> Tier -> limits | `kyc_tier` |
| Customer/Agent -> Country -> Currency | `country` |
| TxnRef -> BillerName -> Category | `biller`, linked via `bill_payment` |

A further design change replaces "agent + customer on a transaction" with **wallets**. A transaction moves money from one wallet to another, so `txn` references `source_wallet_id` and `dest_wallet_id`, and the wallet resolves to its owner. This removes the empty agent columns seen on the BILL_PAY row above.

## BCNF check

Every determinant in the final schema is a candidate key of its table:

- `customer`: determinants are `customer_id` (PK) and `msisdn` (UNIQUE). Both are candidate keys.
- `agent`: `agent_id`, `agent_code` and `msisdn`. All candidate keys.
- `biller`: `biller_id`, and `(biller_name, country_code)` (UNIQUE).
- `kyc_document`: `document_id`, and `(document_type, document_ref)` (UNIQUE).

The schema therefore satisfies BCNF.

## Deliberate, controlled denormalisation

Two columns are intentionally redundant:

1. **`wallet.balance`** can be derived as the sum of the wallet's ledger entries. It is stored because the balance check sits on the hot path of every transfer, and summing thousands of ledger rows per request would not scale. The redundancy is controlled in two ways:
   - The ledger stays the source of truth.
   - Reconciliation query V2 in `03_constraint_tests.sql` proves the two agree (expected result: 0 rows).
2. **`ledger_entry.balance_after`** is a running balance stored for statement generation and dispute resolution. It makes "what was my balance after transaction X?" a single-row lookup.

These choices are a trade-off between write consistency and read performance. Portfolio 3 makes them safe under concurrency by updating the balance and inserting the ledger rows in one ACID transaction.
