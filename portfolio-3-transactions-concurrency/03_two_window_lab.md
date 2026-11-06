# Part C: Two-Window Concurrency Lab

These experiments need **two sessions running at the same time**, as if two customers or two app servers were using the database at once. Open **two Terminal windows** side by side.

## Start the two sessions

**Window A**
```bash
docker exec -it kashlink-postgres psql -U postgres -d kashlink
\i /portfolio/portfolio-3-transactions-concurrency/lab/session_a.sql
```

**Window B**
```bash
docker exec -it kashlink-postgres psql -U postgres -d kashlink
\i /portfolio/portfolio-3-transactions-concurrency/lab/session_b.sql
```

The prompts change to `WINDOW-A >` and `WINDOW-B >`. A `*` appears in the prompt while a transaction is open, and `!` appears once a transaction has failed.

Reset the demo wallets once, in either window:
```sql
SELECT demo_reset();
```

Run the steps **in the order shown**, switching windows as indicated. 📸 marks a good point for a screenshot.

---

## Lab 1: Isolation levels (READ COMMITTED vs REPEATABLE READ)

**Question:** if Ada's balance changes while a report is running, does the report see the change?

### 1a. READ COMMITTED (PostgreSQL default)

| Step | Window A | Window B |
|---|---|---|
| 1 | `BEGIN;` | |
| 2 | `SELECT balance FROM wallet WHERE wallet_id = :ada;` → **1,000,000.00** | |
| 3 | | `SELECT p2p_transfer('2348000000001','2348000000003',1000);` (auto-commits) |
| 4 | `SELECT balance FROM wallet WHERE wallet_id = :ada;` → **999,000.00** 📸 | |
| 5 | `COMMIT;` | |

**Result: non-repeatable read.** The same query returned two different values inside one transaction, because each statement sees the data committed before *that statement* started.

### 1b. REPEATABLE READ

| Step | Window A | Window B |
|---|---|---|
| 1 | `BEGIN ISOLATION LEVEL REPEATABLE READ;` | |
| 2 | `SELECT balance FROM wallet WHERE wallet_id = :ada;` → **999,000.00** | |
| 3 | | `SELECT p2p_transfer('2348000000001','2348000000003',1000);` |
| 4 | `SELECT balance FROM wallet WHERE wallet_id = :ada;` → still **999,000.00** 📸 | |
| 5 | `COMMIT;` then run the SELECT again → **998,000.00** | |

**Result:** the whole transaction reads one consistent snapshot, taken at its first query. This suits month-end statements and reconciliation reports, where every figure must come from the same moment.

---

## Lab 2: Write conflict, where waiting vs failing depends on the isolation level

Two transfers from Ada start at the same moment.

### 2a. REPEATABLE READ: the second writer fails

| Step | Window A | Window B |
|---|---|---|
| 1 | `BEGIN ISOLATION LEVEL REPEATABLE READ;` | `BEGIN ISOLATION LEVEL REPEATABLE READ;` |
| 2 | `SELECT balance FROM wallet WHERE wallet_id = :ada;` | `SELECT balance FROM wallet WHERE wallet_id = :ada;` |
| 3 | `SELECT p2p_transfer('2348000000001','2348000000003',500);` | |
| 4 | | `SELECT p2p_transfer('2348000000001','2348000000004',500);` → **hangs, waiting for A's row lock** 📸 |
| 5 | `COMMIT;` | → `ERROR: could not serialize access due to concurrent update` 📸 |
| 6 | | `ROLLBACK;` |

**Result:** B's snapshot is out of date, because A changed Ada's row after B's snapshot was taken. PostgreSQL refuses to let B act on stale data. The application must **retry** the whole transaction.

### 2b. READ COMMITTED: the second writer waits, then succeeds

| Step | Window A | Window B |
|---|---|---|
| 1 | `BEGIN;` | `BEGIN;` |
| 2 | `SELECT p2p_transfer('2348000000001','2348000000003',500);` | |
| 3 | | `SELECT p2p_transfer('2348000000001','2348000000004',500);` → **hangs** |
| 4 | `COMMIT;` | → completes and returns a txn_id 📸 |
| 5 | | `COMMIT;` |

**Result:** `SELECT ... FOR UPDATE` inside `p2p_transfer` makes B **wait** for A's lock, then re-read the *latest* balance before checking funds. Both transfers succeed and nothing is lost. This is the pessimistic locking that made the Part B stress test correct.

---

## Lab 3: Deadlock, and how lock ordering prevents it

### 3a. Causing a deadlock (opposite lock order)

| Step | Window A | Window B |
|---|---|---|
| 1 | `BEGIN;` | `BEGIN;` |
| 2 | `UPDATE wallet SET version = version + 1 WHERE wallet_id = :ada;` | |
| 3 | | `UPDATE wallet SET version = version + 1 WHERE wallet_id = :bola;` |
| 4 | `UPDATE wallet SET version = version + 1 WHERE wallet_id = :bola;` → **hangs** (waits for B) | |
| 5 | | `UPDATE wallet SET version = version + 1 WHERE wallet_id = :ada;` → after ~1 s: **`ERROR: deadlock detected`** 📸 |
| 6 | A's update now completes → `COMMIT;` | `ROLLBACK;` |

**Result:** A holds Ada and wants Bola, while B holds Bola and wants Ada, so neither can proceed. PostgreSQL's deadlock detector (`deadlock_timeout` = 1 s) cancels one transaction so the other can finish.

### 3b. Same opposite transfers, using `p2p_transfer()`

| Step | Window A | Window B |
|---|---|---|
| 1 | `BEGIN;` | `BEGIN;` |
| 2 | `SELECT p2p_transfer('2348000000001','2348000000002',100);` (Ada → Bola) | |
| 3 | | `SELECT p2p_transfer('2348000000002','2348000000001',100);` (Bola → Ada) → **hangs, but does not deadlock** |
| 4 | `COMMIT;` | → completes 📸 → `COMMIT;` |

**Result:** `p2p_transfer` always locks the **lower wallet_id first**, whichever direction the money moves. Both sessions queue for the same first lock, so a circular wait is impossible.

---

## Finish: confirm nothing was corrupted

Run in either window:
```sql
SELECT name, balance FROM demo_wallets;
SELECT sum(balance) AS total FROM demo_wallets;   -- must be 4000000.00
SELECT * FROM demo_reconciliation;                -- must be 0 rows
```
📸 Then type `\q` in both windows.
