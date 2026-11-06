# Portfolio 3: Transactions and Concurrency

**Case study:** KashLink Mobile Money (simulated) · **DBMS:** PostgreSQL 16 · **Tools:** psql, pgbench

## 1. Why transactions matter for KashLink

A P2P transfer is several writes: insert the transaction, debit the sender, credit the recipient, and post two ledger rows. If only some of them happen, money is created or destroyed. Thousands of customers and agents also transact at the same moment, often on the same wallets (a busy agent's float, for example). This portfolio shows how PostgreSQL's **ACID** guarantees and **concurrency control** keep balances correct, and what goes wrong without them.

| ACID property | Where it is demonstrated |
|---|---|
| **Atomicity** | Demos 2, 3, 4, 5: rolled-back work leaves no trace |
| **Consistency** | CHECK `balance >= 0` aborts an overdraft (Demo 3). Total money stays constant after every test. Ledger reconciliation returns 0 rows |
| **Isolation** | Lab 1 (READ COMMITTED vs REPEATABLE READ) and Lab 2 |
| **Durability** | Demo 1: after `COMMIT` the change is permanent. PostgreSQL writes it to the WAL (write-ahead log) before confirming, so it survives a crash or a container restart |

## 2. The safe transfer function

[`00_setup.sql`](00_setup.sql) creates four demo customers (Ada, Bola, Chidi, Dayo, NGN 1,000,000 each) and `p2p_transfer()`, which:

1. **Is idempotent.** If `txn_ref` was already used, it returns the original transaction rather than charging twice.
2. **Locks both wallets** with `SELECT ... FOR UPDATE`, **always in ascending wallet_id order** (deadlock prevention).
3. **Re-reads the balance after locking** and checks status, currency, funds and the KYC tier daily limit.
4. Writes the `txn` row, both balance updates (incrementing `version`) and both ledger rows.

Any failed check raises an exception, which rolls back everything in the caller's transaction.

## 3. Part A: COMMIT, ROLLBACK and recovery from failure

Script: [`01_commit_rollback.sql`](01_commit_rollback.sql) · Output: [`results/01_commit_rollback.txt`](results/01_commit_rollback.txt)

| Demo | Scenario | Outcome |
|---|---|---|
| 1 COMMIT | Ada → Bola NGN 5,000 | Balances change and two ledger rows (D/C) are written, permanently |
| 2 ROLLBACK | Ada → Bola NGN 7,000, then cancelled | Inside the transaction the money had moved. After `ROLLBACK`, balances and the txn count are unchanged |
| 3 Atomicity | Manual 2-step transfer: credit Dayo +2M, then debit Chidi −2M (who has 1M) | Debit violates `CHECK (balance >= 0)`. The transaction is aborted (`current transaction is aborted…`) and Dayo **does not keep the credit** |
| 4 Business rule | `p2p_transfer` for more than the balance | `Insufficient funds`. Nothing is written |
| 5 SAVEPOINT | Batch of 3 payments; payment 2 targets a FROZEN wallet | `ROLLBACK TO SAVEPOINT` undoes only payment 2. Payments 1 and 3 commit |
| 6 Idempotency | Same request (same UUID) sent twice, e.g. after a network timeout | Second call returns the first txn_id. Customer charged once |
| 7 Optimistic locking | Two agents edit the same wallet based on the same `version` | First update succeeds (`UPDATE 1`). Second matches no row (`UPDATE 0`), so the conflict is detected without holding locks |

**Final check:** total demo money = NGN 4,000,000.00 and reconciliation returns 0 rows.

## 4. Part B: the lost update problem under real concurrency

Script: [`02_stress_test.sh`](02_stress_test.sh) uses **pgbench** to run **20 concurrent clients × 50 transfers** of NGN 100 from Ada to Bola (1,000 transfers, NGN 100,000).

| | Naive read-modify-write | Safe `p2p_transfer()` |
|---|---|---|
| Approach | App reads balance, computes new value, writes it back. No locks | One call: lock rows, re-read, update, ledger |
| Transfers processed | 1,000 / 1,000, **0 failed** | 1,000 / 1,000, 0 failed |
| Ada final balance (expected 900,000) | 994,300.00 ✘ (only 57 of 1,000 debits survived) | 900,000.00 ✔ |
| Bola final balance (expected 1,100,000) | 1,006,500.00 ✘ (only 65 of 1,000 credits survived) | 1,100,000.00 ✔ |
| Money created / lost | **+NGN 800.00 created from nothing** ✘ | 0.00 ✔ |
| Transfer records / ledger | 0 txn rows; cached balances no longer match the ledger | 1,000 txn rows; reconciliation 0 rows ✔ |
| Throughput | 3,782 tps (5.3 ms avg latency) | 1,385 tps (14.4 ms avg latency) |

**Analysis.** In the naive version, two clients read the same balance (say 999,900), both subtract 100, and both write 999,800. One debit is silently lost. **pgbench reported 0 failed transactions**, yet 943 of 1,000 debits vanished and NGN 800 was created from nothing. That is the most dangerous kind of bug for a payments company: it does not show up until reconciliation. Under READ COMMITTED, a plain `UPDATE ... SET balance = <value calculated in the app>` is not protected.

The safe version fixes this with **pessimistic row locking**. `FOR UPDATE` makes concurrent transfers on the same wallet queue one behind another, and each one re-reads the committed balance. Correctness costs throughput (1,385 vs 3,782 tps, about 63% lower) because every transfer on the same hot wallet must queue for its row lock. That is an acceptable trade for money movement. Transfers between *different* wallets still run in parallel, because locks are per row, not per table.

## 5. Part C: isolation levels, write conflicts and deadlocks

Guide: [`03_two_window_lab.md`](03_two_window_lab.md). Run in two Terminal windows. Screenshots are in [`evidence/`](evidence/).

| Lab | Observation | Lesson |
|---|---|---|
| 1a READ COMMITTED | Same SELECT returns 1,000,000 then 999,000 in one transaction | **Non-repeatable read.** Each statement sees the latest committed data |
| 1b REPEATABLE READ | Same SELECT returns 999,000 twice despite a concurrent commit | Snapshot isolation (MVCC). Suitable for consistent reports |
| 2a REPEATABLE READ write conflict | Second transfer waits, then `could not serialize access due to concurrent update` | PostgreSQL will not let a transaction act on stale data. The app must retry |
| 2b READ COMMITTED + `FOR UPDATE` | Second transfer waits, then succeeds with the fresh balance | Pessimistic locking serialises access to the same row |
| 3a Opposite lock order | `ERROR: deadlock detected` after ~1 s | The deadlock detector breaks the cycle by aborting one victim |
| 3b Opposite transfers via `p2p_transfer` | Second session waits, then completes. No deadlock | **Consistent lock ordering** prevents deadlocks by design |

**Design decision.** KashLink runs at **READ COMMITTED with explicit `FOR UPDATE` locks** for money movement. Every transfer succeeds or fails cleanly with no retry loop, and correctness is still guaranteed. **REPEATABLE READ** is used for read-only reports that need one consistent snapshot. **Optimistic locking** (the `version` column) is used for low-contention back-office edits, where holding locks while a person decides would be wasteful.

## 6. How to run

From the repository root:

```bash
P=/portfolio/portfolio-3-transactions-concurrency
docker exec kashlink-postgres psql -U postgres -d kashlink -f $P/00_setup.sql
docker exec kashlink-postgres psql -U postgres -d kashlink -f $P/01_commit_rollback.sql > portfolio-3-transactions-concurrency/results/01_commit_rollback.txt 2>&1
bash portfolio-3-transactions-concurrency/02_stress_test.sh | tee portfolio-3-transactions-concurrency/results/02_stress_test.txt
```
Then follow [`03_two_window_lab.md`](03_two_window_lab.md).

## 7. Files

| File | Purpose |
|---|---|
| `00_setup.sql` | Demo wallets, `p2p_transfer()`, `demo_reset()`, reconciliation view |
| `01_commit_rollback.sql` | Part A: 7 scripted transaction demos |
| `02_stress_test.sh` + `stress/` | Part B: pgbench naive vs safe concurrency test |
| `03_two_window_lab.md` + `lab/` | Part C: interactive isolation and deadlock experiments |
| `results/` | Captured output |
| `evidence/` | Screenshots |
