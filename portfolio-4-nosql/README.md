# Portfolio 4: NoSQL and Advanced Data Models

**Case study:** KashLink Mobile Money (simulated), the same organisation as Portfolios 1–3
**DBMS:** MongoDB 7 (document store) · **Shell:** mongosh · **Data:** 2,006 customers, 30,006 transactions (seeded, reproducible)

## 1. Why a NoSQL model for KashLink?

The PostgreSQL design from Portfolio 1 is right for money: balances, ledger and transfers need strict constraints and multi-row ACID transactions. Several other parts of KashLink fit tables poorly:

| Data | Problem in the relational model |
|---|---|
| **KYC documents** | Each regulator needs different fields. Nigeria uses NIN + BVN (with bank), Ghana uses the Ghana Card (card number + **expiry**), Uganda uses a National ID (NIN + card number + district). In SQL this means many nullable columns or an extra table per document type. |
| **Channel metadata** | A USSD session has a short code and network. An app transaction has device, OS, app version, IP and GPS location. An agent transaction has an agent code and location. An API call has a partner ID. One table would be mostly NULLs. |
| **Devices, beneficiaries, tags** | Small lists that belong to one customer and are always read with that customer. Relational design needs a child table and a join each time. |
| **App reads** | The login screen needs profile + wallet + KYC status + devices in one round-trip. The statement screen needs a month of entries with counterparty names. |
| **Fraud analytics** | "Where did this money go next?" is a graph question. In SQL it needs recursive CTEs. |

A **document model** handles these naturally: each record carries its own structure, related data that is read together is stored together, and new optional fields need no schema migration.

## 2. Document model

Three collections, with each embed-or-reference decision driven by how the data is accessed:

| Collection | One document = | Key design decisions |
|---|---|---|
| `customers` | One customer | `_id` = **MSISDN** (phone number), so profile lookup is key-value access. **Embedded:** `wallet` (1:1), `kyc.documents` (polymorphic per country), `devices` (max 5, enforced), `beneficiaries` (small, bounded), `preferences`. **Optional fields appear only when relevant:** 697 USSD-only customers have no `devices` field at all; `merchant` exists only for merchants. |
| `transactions` | One transaction | Parties are **snapshots** (`from: {msisdn, name}`). The statement shows the name as it was at the time of the transfer, which is the correct historical record, and needs no join. `channel_meta` **changes shape by channel**. `failure` exists only on failed transactions. App/agent locations are GeoJSON points. |
| `statements` | One customer × one month | **Bucket pattern.** It is built from `transactions` with an aggregation `$merge`, so the statement screen is a single read. It is a read model that can be rebuilt at any time; it is not the source of truth. |

### Same entity, different shapes (from `01_load_data.js` output)

```js
// Nigerian customer: NIN + BVN                // Ghanaian customer: Ghana Card with expiry
kyc: { documents: [                            kyc: { documents: [
  { type: 'NIN', nin: '10000000006',             { type: 'GHANA_CARD',
    verified: true, verified_at: ISODate(…) },     card_number: 'GHA-700001401-6',
  { type: 'BVN', bvn: '22000000006',               expiry: ISODate('2028-08-01'),
    bank: 'Access', verified: true } ] }           verified: true, verified_at: ISODate(…) } ] }

// USSD transaction                            // App transaction
channel_meta: { short_code: '*565#',           channel_meta: { device_id: 'DEV-1407-0', os: 'Android',
  session_id: 'S000000006', network: 'Glo' }     app_version: '4.9.0', ip: '102.89.28.88', city: 'Accra',
                                                 geo: { type: 'Point', coordinates: [-0.19121, 5.62801] } }
```

### Relational → document mapping

| PostgreSQL (Portfolio 1) | MongoDB (this portfolio) |
|---|---|
| `customer` + `wallet` + `kyc_document` (3 tables, 2 joins) | 1 `customers` document |
| `kyc_document.document_type` + fixed columns | Array of sub-documents, each with its own fields |
| `txn` + `bill_payment` subtype table | 1 `transactions` document with an optional `biller` sub-document |
| FK `txn.source_wallet_id` → join to get the name | Embedded `from` snapshot |
| `CHECK` constraints | `$jsonSchema` validator (Q8) |
| Ledger statement query (Portfolio 2 Q1) | Pre-built `statements` bucket (Q10) |

## 3. Implementation evidence: queries and operations

Script: [`02_queries.js`](02_queries.js) · Output: [`results/02_queries.txt`](results/02_queries.txt)

| # | Capability | Result |
|---|---|---|
| Q1 | **Key-value access** by `_id` (MSISDN) | Whole profile (wallet, 2 KYC docs, 2 devices, beneficiary) from 1 document read, 0 joins |
| Q2 | **Nested, polymorphic queries** (`$elemMatch`) | 281 customers with an unverified KYC document (NG 199, GH 54, UG 28). **66** Ghana Cards expire before 2027. **49** Tier 2+ Nigerians lack a BVN |
| Q3 | **Array query** on `devices` | **706** Android users on app version < 5.0 (forced-upgrade target list) |
| Q4 | **Aggregation pipeline** | October volume by country × channel, the same question as Portfolio 2 Q3 in SQL |
| Q5 | **Geospatial** (`2dsphere`, `$geoWithin`, `$near`) | **398** app transactions within 5 km of Ikeja, Lagos |
| Q6 | **Atomic conditional update** | `updateOne({balance ≥ 5,000}, {$inc: −5,000})` → modified 1. The same for 99,999,999 → modified 0. Check and change are one atomic step, so no lost update |
| Q7 | **Array operators** | `$push` with `$slice: -5` keeps only the 5 latest devices. `$addToSet` avoids duplicate tags |
| Q8 | **Schema validation** | Invalid document **rejected** (bad MSISDN, unknown country, tier 9, negative balance). A valid document with a brand-new `loyalty` field **accepted** without a migration |
| Q9 | **Graph traversal** (`$graphLookup`) | From one flagged account, it follows large transfers within 24 h and finds a **5-account cycle**: money returns to the start, hops are ~11 minutes apart, ~3–4% is skimmed per hop, and every hop uses one shared device. This is a money-mule ring |
| Q10 | **Bucket pattern** (`$merge`) | 5,971 monthly statement documents. One read returns a month's entries and totals |

## 4. Index evaluation

Script: [`03_indexes.js`](03_indexes.js) · Output: [`results/03_indexes.txt`](results/03_indexes.txt)

| # | Query | Index | Before | After |
|---|---|---|---|---|
| E1 | Last 10 transfers by a customer, newest first | Compound `{from.msisdn: 1, ts: -1}` | `COLLSCAN` + in-memory `SORT`, **30,006 docs examined** | `IXSCAN`, **10 docs examined**, no sort |
| E2 | Ghana Cards expiring before 2027 | **Multikey** compound on `kyc.documents.type` + `expiry` | `COLLSCAN`, 2,006 docs | `IXSCAN`, 66 docs (all returned) |
| E3 | 20 latest FAILED transactions | **Partial** `{ts: -1}` where `status = 'FAILED'` | `COLLSCAN` + `SORT`, 30,006 docs | `IXSCAN`, 20 docs, **37 kB index** (vs 311 kB for `_id`) |

These are the same principles as PostgreSQL in Portfolio 2: put the equality field first and the sort field second, and index only the rows the query needs. MongoDB adds **multikey** indexes, which index every element of an array.

## 5. Suitability analysis

### Where MongoDB is the better fit for KashLink
- **Customer profile and KYC store.** Structure varies by country and changes with regulation, so new document types or fields need no migration (Q8). It is read as one unit at login (Q1).
- **Channel event and telemetry data.** Fields differ by channel. It is high-volume and append-only, and geospatial queries help fraud and agent-network planning (Q5).
- **Read models for the app.** Statements and activity feeds are pre-shaped for the screen (Q10).
- **Fraud investigation.** `$graphLookup` answers "follow the money" in one query (Q9). A dedicated graph database such as Neo4j would be stronger at scale; `$graphLookup` is enough for occasional investigations.

### Where MongoDB is the wrong fit: the ledger stays in PostgreSQL
- **A transfer changes two wallets.** MongoDB guarantees atomicity **per document** (Q6), but a P2P transfer must debit one document and credit another. MongoDB does support multi-document transactions, but **only on a replica set or sharded cluster** (not the standalone instance used here). They also carry a performance cost and are not the model's natural strength.
- **Integrity rules span collections.** Rules such as "every ledger entry belongs to an existing transaction" and "debits equal credits" are enforced by foreign keys and CHECK constraints in PostgreSQL. `$jsonSchema` validates one document at a time and cannot enforce relationships between collections.
- **Denormalised snapshots can drift.** The embedded `wallet.balance` in `customers` is a cached copy. If it were the only copy, keeping it consistent with transactions would fall to application code: exactly the lost-update risk shown in Portfolio 3.

### Other NoSQL models considered

| Model | KashLink use case | Decision |
|---|---|---|
| **Document** (MongoDB) | Profiles, KYC, channel events, statements | ✔ Implemented: matches the variable, nested, read-together data |
| **Key-value** (e.g. Redis) | USSD session state, OTP codes, idempotency keys, rate limits, all with a time-to-live | Good complement for short-lived data. Q1 shows the key-value access pattern inside MongoDB |
| **Wide-column** (e.g. Cassandra) | Billions of network/USSD event records written continuously across regions | Considered for very high write volumes. Over-engineered at KashLink's current scale |
| **Graph** (e.g. Neo4j) | Fraud rings, agent-to-customer networks | Shown with `$graphLookup` (Q9). A dedicated graph database is justified once fraud analytics becomes continuous |

**Conclusion: polyglot persistence.** PostgreSQL remains the **system of record** for money (wallets, transactions, ledger). MongoDB holds **customer and KYC profiles, channel events and read models**, fed from PostgreSQL by change-data-capture (for example an outbox table streamed through Kafka/Debezium). Each engine is used for what it does best. Portfolio 5 looks at how these stores are distributed across KashLink's three countries.

## 6. How to run

The Docker setup mounts this repository into the MongoDB container (see `docker-compose.yml`). From the repository root:

```bash
docker compose up -d        # applies the volume mount to the mongo container (one time)
docker exec kashlink-mongo mongosh --quiet kashlink_nosql --file /portfolio/portfolio-4-nosql/01_load_data.js > portfolio-4-nosql/results/01_load_data.txt
docker exec kashlink-mongo mongosh --quiet kashlink_nosql --file /portfolio/portfolio-4-nosql/02_queries.js   > portfolio-4-nosql/results/02_queries.txt
docker exec kashlink-mongo mongosh --quiet kashlink_nosql --file /portfolio/portfolio-4-nosql/03_indexes.js   > portfolio-4-nosql/results/03_indexes.txt
```

`01_load_data.js` drops and rebuilds the database. The data is generated with a seeded random generator, so counts are identical on every run.

## 7. Files

| File | Purpose |
|---|---|
| `01_load_data.js` | Creates collections with `$jsonSchema` validation, loads seeded data and the hidden fraud ring, prints sample documents |
| `02_queries.js` | Q1–Q10: key-value, nested, array, aggregation, geospatial, atomic update, validation, graph, bucket pattern |
| `03_indexes.js` | E1–E3: `explain('executionStats')` before and after compound, multikey and partial indexes |
| `results/` | Captured output |
| `evidence/` | Screenshots |
