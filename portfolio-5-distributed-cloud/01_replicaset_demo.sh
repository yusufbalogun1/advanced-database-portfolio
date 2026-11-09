#!/usr/bin/env bash
# =====================================================================
# Portfolio 5 - Part A: MongoDB replica set (replication, transactions,
# automatic failover, and behaviour when the majority is lost)
#
# Run from the repository root:
#   bash portfolio-5-distributed-cloud/01_replicaset_demo.sh | tee portfolio-5-distributed-cloud/results/01_replicaset_demo.txt
# Takes about 2-3 minutes. Remove the cluster afterwards with:
#   docker compose -f portfolio-5-distributed-cloud/docker-compose.replicaset.yml down
# =====================================================================
set -u
cd "$(dirname "$0")"
COMPOSE="docker compose -f docker-compose.replicaset.yml"
SET="mongodb://mongo1:27017,mongo2:27017,mongo3:27017/kashlink?replicaSet=klrs&serverSelectionTimeoutMS=8000&readPreference=secondaryPreferred"

step()      { echo; echo "======================================================================"; echo " $1"; echo "======================================================================"; }
wait_node() { for i in $(seq 1 60); do
                docker exec kl-client mongosh --quiet "mongodb://$1:27017/?directConnection=true" \
                  --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1 && return 0; sleep 1; done
              echo "  (node $1 did not respond)"; }
primary()   { docker exec kl-client mongosh --quiet "$SET" --eval 'db.hello().primary || ""' 2>/dev/null | tail -1; }
status()    { docker exec kl-client mongosh --quiet --nodb --file /p5/replicaset/status.js; }
write()     { docker exec -e KL_NOTE="$1" kl-client mongosh --quiet "$SET" --file /p5/replicaset/write_test.js; }

step "STEP 1  Start three MongoDB nodes (mongo1, mongo2, mongo3) and a client container"
$COMPOSE up -d
for n in mongo1 mongo2 mongo3; do wait_node $n; done
echo "  All three nodes are running."

step "STEP 2  Form the replica set 'klrs' and elect a primary"
docker exec kl-client mongosh --quiet "mongodb://mongo1:27017/?directConnection=true" --file /p5/replicaset/init.js | tail -1
sleep 3
status

step "STEP 3  REPLICATION + MULTI-DOCUMENT TRANSACTIONS"
docker exec kl-client mongosh --quiet "$SET" --file /p5/replicaset/replicate_and_txn.js
sleep 2
echo
echo "  Every node now holds the same data (asked each node directly):"
status

step "STEP 4  AVAILABILITY: stop the PRIMARY and watch automatic failover"
OLD=$(primary)
echo "  Current primary: $OLD -> stopping container kl-${OLD%%:*}"
docker stop "kl-${OLD%%:*}" >/dev/null
T0=$(date +%s)
NEW=""
for i in $(seq 1 60); do
  NEW=$(primary)
  if [ -n "$NEW" ] && [ "$NEW" != "$OLD" ]; then break; fi
  sleep 1
done
echo "  New primary elected: $NEW  (about $(( $(date +%s) - T0 )) seconds after the old primary stopped)"
write "written during failover"
status

step "STEP 5  CONSISTENCY over availability: stop a SECOND node (only 1 of 3 left)"
NEW=$(primary)
echo "  Stopping the current primary $NEW -> container kl-${NEW%%:*}"
docker stop "kl-${NEW%%:*}" >/dev/null
sleep 5
echo "  Trying a majority write and a read with only one node alive:"
write "written with majority lost"
status

step "STEP 6  RECOVERY: restart the stopped nodes; they rejoin and catch up automatically"
docker start "kl-${OLD%%:*}" "kl-${NEW%%:*}" >/dev/null
for n in mongo1 mongo2 mongo3; do wait_node $n; done
sleep 15
status
echo
echo "  The write made during failover (Step 4) is now on ALL nodes, including the ones that were down."
echo "  Done. Remove the cluster with: docker compose -f portfolio-5-distributed-cloud/docker-compose.replicaset.yml down"
