// =====================================================================
// Portfolio 4 - Index evaluation on MongoDB with explain('executionStats')
// Each query is measured with NO supporting index, then WITH one.
// Run:  docker exec kashlink-mongo mongosh --quiet kashlink_nosql --file /portfolio/portfolio-4-nosql/03_indexes.js
// =====================================================================
const IDX = ['ix_statement', 'ix_kyc_type_expiry', 'ix_failed_recent'];
IDX.forEach(n => { try { db.transactions.dropIndex(n); } catch (e) {} try { db.customers.dropIndex(n); } catch (e) {} });

function stages(p) {                        // flatten the winning plan into "STAGE <- STAGE" form
  if (!p) return [];
  p = p.queryPlan || p;
  const kids = p.inputStage ? [p.inputStage] : (p.inputStages || []);
  return [p.stage + (p.indexName ? '(' + p.indexName + ')' : '')].concat(...kids.map(stages));
}
function measure(label, cursorFn) {
  const ex = cursorFn().explain('executionStats');
  const s = ex.executionStats;
  print('  ' + label.padEnd(10) + ' plan: ' + stages(ex.queryPlanner.winningPlan).join(' <- '));
  print('  ' + ''.padEnd(10) + ' returned: ' + s.nReturned + ' | keys examined: ' + s.totalKeysExamined +
        ' | docs examined: ' + s.totalDocsExamined + ' | time: ' + s.executionTimeMillis + ' ms');
  return s;
}
const h = t => print('\n' + '='.repeat(78) + '\n' + t + '\n' + '='.repeat(78));
const total = db.transactions.countDocuments(), totalC = db.customers.countDocuments();
print('Collection sizes: transactions = ' + total + ', customers = ' + totalC);

// ---------------------------------------------------------------------
h('E1  Mini-statement: last 10 transfers sent by one customer (newest first)');
const q1 = () => db.transactions.find({ 'from.msisdn': '2349000000006' }).sort({ ts: -1 }).limit(10);
measure('BEFORE', q1);
db.transactions.createIndex({ 'from.msisdn': 1, ts: -1 }, { name: 'ix_statement' });
measure('AFTER', q1);
print('  Compound index: equality field first, sort field second -> no in-memory SORT, stops after 10.');

// ---------------------------------------------------------------------
h('E2  KYC compliance: Ghana Cards expiring before 2027 (MULTIKEY index on an array of sub-documents)');
const q2 = () => db.customers.find({ 'kyc.documents': { $elemMatch: { type: 'GHANA_CARD', expiry: { $lt: ISODate('2027-01-01') } } } });
measure('BEFORE', q2);
db.customers.createIndex({ 'kyc.documents.type': 1, 'kyc.documents.expiry': 1 }, { name: 'ix_kyc_type_expiry' });
measure('AFTER', q2);
print('  MongoDB indexes every element of the documents array (multikey), so one customer can have several');
print('  index keys. With type first, the scan jumps straight to GHANA_CARD entries and their expiry range.');

// ---------------------------------------------------------------------
h('E3  Ops monitor: 20 most recent FAILED transactions (PARTIAL index)');
const q3 = () => db.transactions.find({ status: 'FAILED', ts: { $gte: ISODate('2026-10-25') } }).sort({ ts: -1 }).limit(20);
measure('BEFORE', q3);
db.transactions.createIndex({ ts: -1 }, { name: 'ix_failed_recent', partialFilterExpression: { status: 'FAILED' } });
measure('AFTER', q3);

// ---------------------------------------------------------------------
h('Index sizes (bytes)');
db.adminCommand({ fsync: 1 });   // flush to disk so the size statistics are current
const ts = db.transactions.stats().indexSizes, cs = db.customers.stats().indexSizes;
Object.keys(ts).forEach(k => print('  transactions.' + k.padEnd(28) + ts[k]));
Object.keys(cs).forEach(k => print('  customers.' + k.padEnd(31) + cs[k]));
print('  The partial index holds only FAILED transactions (~5%), so it is a fraction of the size of a full-collection index such as _id.');
