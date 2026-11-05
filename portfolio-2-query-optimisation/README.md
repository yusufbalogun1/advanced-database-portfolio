# Portfolio 2: Query Processing and Optimisation

**Case study:** KashLink Mobile Money (simulated). Same schema as [Portfolio 1](../portfolio-1-database-design/).
**DBMS:** PostgreSQL 16 · **Method:** `EXPLAIN (ANALYZE, BUFFERS)` before and after targeted optimisation.

## 1. Objective

Identify six realistic KashLink queries, measure how PostgreSQL executes them at production-like volume, then improve each one with the most suitable technique and explain the result. The aim is to justify each technique, not to add indexes everywhere.

## 2. Test dataset

`01_generate_data.sql` adds reproducible synthetic data on top of the Portfolio 1 seed. It uses `setseed(0.42)`, so every run produces the same data.

| Table | Rows | Notes |
|---|---|---|
| customer | 50,010 | 70% Nigeria, 20% Ghana, 10% Uganda |
| agent | 1,003 | |
| wallet | 51,013 | One per customer/agent |
| txn | 551,022 | 2 Jan to 31 Oct 2026. Mix: 55% P2P, 20% bill pay, 15% cash-out, 10% cash-in. Status: 93% success, 5% failed, 2% pending |
| ledger_entry | 888,207 | Double-entry rows for every successful transaction |

The data still passes every Portfolio 1 constraint. No balance goes negative and the ledger still reconciles.

## 3. Workload queries

| # | Business need | User | Query pattern |
|---|---|---|---|
| Q1 | Mini-statement: last 10 movements for a wallet | Customer app | Equality filter + ORDER BY + LIMIT |
| Q2 | Find a customer by name, ignoring case | Support desk | Function applied to the column |
| Q3 | October volume by channel and type | Finance | Date-range scan + aggregation |
| Q4 | Top 10 agents by cash-out value, last 30 days | Agent management | Filtered join + aggregation + top-N |
| Q5 | Latest failed/pending transactions | Operations | Rare-value filter + ORDER BY |
| Q6 | Wallets with no activity since 1 Aug | Marketing | Anti-join (query rewrite) |

Query results are in [`results/query_results.txt`](results/query_results.txt).

## 4. Results: before vs after

| # | Baseline plan | Time | Optimisation | Optimised plan | Time | Speed-up |
|---|---|---|---|---|---|---|
| Q1 | Seq Scan on ledger_entry (888,200 rows discarded) + Sort | 29.0 ms | Composite B-tree `(wallet_id, posted_at DESC)` | Index Scan, no sort | 0.016 ms | ~1,800× |
| Q2 | Seq Scan on customer (49,956 rows discarded) | 6.7 ms | Expression index on `(lower(last_name), lower(first_name))` | Bitmap Index Scan | 0.039 ms | ~170× |
| Q3 | Seq Scan on txn (504,745 rows discarded) | 44.4 ms | **BRIN** index on `created_at` (24 kB) | Bitmap scan on BRIN | 12.7 ms | ~3.5× |
| Q4 | Seq Scan on txn (544,312 rows discarded) | 48.7 ms | **Partial + covering** index on successful CASH_OUT rows | **Index Only Scan**, Heap Fetches: 0 | 3.2 ms | ~15× |
| Q5 | Seq Scan on txn (550,341 rows discarded) + Sort | 52.7 ms | **Partial** index `WHERE status IN ('FAILED','PENDING')` | Index Scan, no sort | 0.021 ms | ~2,500× |
| Q6 | `NOT IN` subquery | 21.5 s, **wrong answer (0)** | Rewritten as `NOT EXISTS` on the ledger | Hash Anti Join | 94 ms, **correct (662)** | ~230× + correct |

*Times come from my own run on Docker Desktop for Mac (warm cache, parallel workers disabled so the plans are easy to compare). The full plans are in [`results/baseline_plans.txt`](results/baseline_plans.txt) and [`results/optimised_plans.txt`](results/optimised_plans.txt). Q6 times come from the direct timed run in [`results/rewrite_demo.txt`](results/rewrite_demo.txt).*

## 5. Analysis

**Q1: composite index with column order matching the query.** Without an index, PostgreSQL read all 888k ledger rows to find 7 and then sorted them. In the index, `wallet_id` comes first (the equality filter) and `posted_at DESC` second (the sort order). The planner jumps to that wallet's entries, which are already in newest-first order, and stops after 10. Both the scan and the sort disappear. The same index also serves account statements and disputes.

**Q2: the index must match the expression.** A plain index on `last_name` cannot be used for `lower(last_name) = 'balogun'`, because the stored values differ from what the query compares. An expression index stores `lower(...)`. Support staff can search however a name is typed, and the query no longer scans every customer.

**Q3: BRIN as a low-cost alternative to a B-tree.** About 9% of transactions fall in October, a wide range. A B-tree on `created_at` would be roughly the size of the primary key (~12 MB). Because transactions are appended in time order, physical position follows `created_at` closely. BRIN stores only the minimum and maximum per block range, so it is **24 kB, about 500× smaller**, and still skips 90% of the table. The trade-off shows in the plan: `Heap Blocks: lossy` and `Rows Removed by Index Recheck: 2256`. BRIN narrows the search to block ranges, and the rows inside them must be rechecked. That suits large append-only logs with range-based reporting.

**Q4: partial + covering index allows an index-only scan.** Only about 14% of rows are successful cash-outs. The partial index stores only those rows (2.7 MB). `INCLUDE (dest_wallet_id, amount)` puts every column the query needs into the index. The plan shows **Index Only Scan** with **Heap Fetches: 0**: the 70 MB table is never read. The remaining time is spent on the join and aggregation, not on scanning.

**Q5: partial index on rare values.** Failed and pending transactions are 7% of rows, and operations staff only ever look at those. Indexing just that subset produces a small index (784 kB) that is already sorted by `created_at DESC`. The query reads 50 index entries and stops.

**Q6: rewriting the query fixed a correctness bug as well as the speed.**
- *Correctness.* `x NOT IN (list)` returns nothing if the list contains a NULL, because `x <> NULL` evaluates to UNKNOWN, not TRUE. Bill payments have a NULL destination wallet (30,044 such rows since August), so the original query silently reported **0 dormant wallets**. That would be wrong data handed to the marketing team.
- *Performance.* The subquery result (~300k rows) was too large to hash in `work_mem`. PostgreSQL therefore re-scanned a materialised list for each of the 50,010 wallets, which costs O(n×m).
- *Fix.* `NOT EXISTS` has correct NULL semantics and becomes a **Hash Anti Join**: each table is read once. It also queries `ledger_entry`, which has exactly one non-null `wallet_id` per row.
- *A finding about indexes.* After adding `idx_ledger_wallet_posted`, the planner **still chose a sequential scan** for Q6b. About 28% of ledger rows fall after 1 August. Reading them sequentially into a hash table is cheaper than 50,010 separate index lookups. An index helps when a query is selective, and this one is not. The cost-based optimiser got that right. Because the plan stayed the same, the Q6b times in the two EXPLAIN files (68 ms and 132 ms) only show normal run-to-run variation on a laptop. They are not a regression.

Full evidence, including the NULL demonstration, is in [`results/rewrite_demo.txt`](results/rewrite_demo.txt).

## 6. Trade-offs considered

| Index | Size | Cost |
|---|---|---|
| idx_ledger_wallet_posted | 27 MB | Updated on every ledger insert (2 per transfer). Justified because statements are the most frequent read in the app. |
| idx_customer_name_ci | 368 kB | Small. Customer inserts are rare. |
| brin_txn_created | 24 kB | Nearly free to maintain on an append-only table. Loses value if old rows are updated or the table is reordered. |
| idx_txn_cashout_cover | 2.7 MB | Only maintained for CASH_OUT rows that succeed. |
| idx_txn_exceptions | 784 kB | Rows enter it only when they fail or are pending. |

Each extra index slows writes, and KashLink is write-heavy. So there is one index per proven query need, with partial and BRIN indexes chosen to keep write cost low. No index was added on `txn.status` alone: with only 3 common values it is not selective enough to help.

## 7. How to run

From the repository root (Docker):

```bash
P=/portfolio/portfolio-2-query-optimisation
docker exec kashlink-postgres psql -U postgres -d kashlink -f $P/01_generate_data.sql      # ~1-2 min, run once
docker exec kashlink-postgres psql -U postgres -d kashlink -f $P/02_queries.sql            > portfolio-2-query-optimisation/results/query_results.txt
docker exec kashlink-postgres psql -U postgres -d kashlink -f $P/03_explain_baseline.sql   > portfolio-2-query-optimisation/results/baseline_plans.txt
docker exec kashlink-postgres psql -U postgres -d kashlink -f $P/04_create_indexes.sql     > portfolio-2-query-optimisation/results/index_creation.txt
docker exec kashlink-postgres psql -U postgres -d kashlink -f $P/05_explain_optimised.sql  > portfolio-2-query-optimisation/results/optimised_plans.txt
docker exec kashlink-postgres psql -U postgres -d kashlink -f $P/06_rewrite_demo.sql       > portfolio-2-query-optimisation/results/rewrite_demo.txt  # ~30 s-2 min
```

`03_explain_baseline.sql` drops the Portfolio 2 indexes first, so the before/after comparison can be repeated at any time.

## 8. Files

| File | Purpose |
|---|---|
| `01_generate_data.sql` | Reproducible bulk data generator |
| `02_queries.sql` | The six queries with their business output |
| `explain_all.sql` | Shared EXPLAIN script, included by 03 and 05 |
| `03_explain_baseline.sql` | Drops optimisation indexes, then captures baseline plans |
| `04_create_indexes.sql` | Creates the five indexes and reports their sizes |
| `05_explain_optimised.sql` | Captures plans after optimisation |
| `06_rewrite_demo.sql` | NOT IN vs NOT EXISTS: correctness and timing |
| `results/` | Captured output from all of the above |
| `evidence/` | Screenshots |
