#!/usr/bin/env bash
# =====================================================================
# Portfolio 3 - Part B: Concurrency stress test (lost update problem)
# 20 concurrent clients each send 50 transfers of NGN 100 from Ada to Bola
# (1,000 transfers = NGN 100,000 in total), first with a NAIVE
# read-modify-write approach, then with the SAFE locking function.
#
# Run from the repository root:   bash portfolio-3-transactions-concurrency/02_stress_test.sh
# =====================================================================
set -u
cd "$(dirname "$0")"

PSQL=${PSQL:-"docker exec -i kashlink-postgres psql -U postgres -d kashlink -q"}
PGBENCH=${PGBENCH:-"docker exec kashlink-postgres pgbench -U postgres -n"}
DIR=${DIR:-/portfolio/portfolio-3-transactions-concurrency}
CLIENTS=20
PER_CLIENT=50

run() {
  local label=$1 script=$2
  echo
  echo "=================================================================="
  echo " $label"
  echo " $CLIENTS concurrent clients x $PER_CLIENT transfers of NGN 100 (Ada -> Bola)"
  echo "=================================================================="
  $PSQL -c "SELECT kashlink.demo_reset();" > /dev/null
  $PGBENCH -c $CLIENTS -j 4 -t $PER_CLIENT -f "$DIR/stress/$script" kashlink 2>&1 \
    | grep -E "number of (clients|transactions actually processed|failed)|latency average|tps ="
  echo
  $PSQL < stress/check.sql
}

run "TEST 1 - NAIVE read-modify-write (no locks)"          naive_transfer.pgbench
run "TEST 2 - SAFE p2p_transfer() with SELECT ... FOR UPDATE" safe_transfer.pgbench

$PSQL -c "SELECT kashlink.demo_reset();" > /dev/null
echo
echo "Done. Demo wallets reset to NGN 1,000,000 each."
