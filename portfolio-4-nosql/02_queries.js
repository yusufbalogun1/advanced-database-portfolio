// =====================================================================
// Portfolio 4 - KashLink on MongoDB: application queries and operations
// Run:  docker exec kashlink-mongo mongosh --quiet kashlink_nosql --file /portfolio/portfolio-4-nosql/02_queries.js
// =====================================================================
const h = t => print('\n' + '='.repeat(78) + '\n' + t + '\n' + '='.repeat(78));
// JSON printer that shows Decimal128 money and Long numbers as plain values
const fmt = d => JSON.stringify(d, (k, v) => (v && v.$numberDecimal !== undefined) ? v.$numberDecimal
                                       : (v && v.low !== undefined && v.high !== undefined) ? v.low : v);
const show = cur => cur.forEach(d => print('  ' + fmt(d)));

// ---------------------------------------------------------------------
h('Q1  KEY-VALUE ACCESS: load a customer\'s whole profile by phone number (app login)');
// One read returns profile + wallet + KYC + devices + beneficiaries.
// In PostgreSQL this needs customer JOIN wallet JOIN kyc_document (+ devices table).
const me = db.customers.findOne({ _id: '2349000000006' });
print('  name: ' + me.name.first + ' ' + me.name.last + ' | tier ' + me.tier + ' | balance ' + me.wallet.currency + ' ' + me.wallet.balance);
print('  KYC documents: ' + me.kyc.documents.map(d => d.type + (d.verified ? ' ✔' : ' ✘')).join(', '));
print('  devices: ' + (me.devices || []).map(d => d.model + ' (v' + d.app_version + ')').join(', '));
print('  beneficiaries: ' + (me.beneficiaries || []).map(b => b.nickname).join(', '));
print('  -> served by the _id primary index: 1 document read, 0 joins');

// ---------------------------------------------------------------------
h('Q2  QUERYING POLYMORPHIC NESTED DATA: KYC compliance follow-up lists');
print('  a) Customers with at least one UNVERIFIED KYC document, by country:');
show(db.customers.aggregate([
  { $match: { 'kyc.documents': { $elemMatch: { verified: false } } } },
  { $group: { _id: '$country', customers: { $sum: 1 } } }, { $sort: { _id: 1 } }]));
print('  b) Ghana Card holders whose card EXPIRES before 1 Jan 2027 (a field only Ghana documents have):');
print('     count = ' + db.customers.countDocuments({ 'kyc.documents': { $elemMatch: { type: 'GHANA_CARD', expiry: { $lt: ISODate('2027-01-01') } } } }));
show(db.customers.find({ 'kyc.documents': { $elemMatch: { type: 'GHANA_CARD', expiry: { $lt: ISODate('2027-01-01') } } } },
                       { 'name.first': 1, 'kyc.documents.expiry': 1 }).limit(3));
print('  c) Tier 2+ Nigerians missing a BVN (regulatory gap):');
print('     count = ' + db.customers.countDocuments({ country: 'NG', tier: { $gte: 2 }, 'kyc.documents.type': { $ne: 'BVN' } }));

// ---------------------------------------------------------------------
h('Q3  ARRAY QUERY: Android users on an app version below 5.0 (forced-upgrade campaign)');
print('  count = ' + db.customers.countDocuments({ devices: { $elemMatch: { os: 'Android', app_version: { $lt: '5.0' } } } }));
show(db.customers.find({ devices: { $elemMatch: { os: 'Android', app_version: { $lt: '5.0' } } } },
                       { _id: 1, 'devices.model': 1, 'devices.app_version': 1 }).limit(3));

// ---------------------------------------------------------------------
h('Q4  AGGREGATION PIPELINE: October 2026 successful volume by country and channel');
// Same business question as Portfolio 2 Q3 (SQL GROUP BY), expressed as a pipeline.
show(db.transactions.aggregate([
  { $match: { status: 'SUCCESS', ts: { $gte: ISODate('2026-10-01'), $lt: ISODate('2026-11-01') } } },
  { $group: { _id: { country: '$country', channel: '$channel' }, txns: { $sum: 1 }, value: { $sum: '$amount' } } },
  { $project: { _id: 0, country: '$_id.country', channel: '$_id.channel', txns: 1, value: { $round: ['$value', 2] } } },
  { $sort: { country: 1, value: -1 } }]));

// ---------------------------------------------------------------------
h('Q5  GEOSPATIAL: app transactions within 5 km of Ikeja, Lagos (2dsphere index)');
const ikeja = [3.3515, 6.6018];
print('  count = ' + db.transactions.countDocuments({ channel: 'APP',
  'channel_meta.geo': { $geoWithin: { $centerSphere: [ikeja, 5 / 6378.1] } } }));
show(db.transactions.find({ channel: 'APP', 'channel_meta.geo': { $near: { $geometry: { type: 'Point', coordinates: ikeja }, $maxDistance: 5000 } } },
                          { _id: 0, ref: 1, amount: 1, 'channel_meta.city': 1, 'channel_meta.geo.coordinates': 1 }).limit(3));

// ---------------------------------------------------------------------
h('Q6  ATOMIC SINGLE-DOCUMENT UPDATE: debit only if funds are sufficient');
// The condition and the change happen in ONE atomic operation: no lost update is possible
// on a single document (compare Portfolio 3's naive read-modify-write).
const who = '2349000000006';
const before = db.customers.findOne({ _id: who }).wallet.balance;
print('  balance before          : ' + before);
let r = db.customers.updateOne({ _id: who, 'wallet.balance': { $gte: NumberDecimal('5000') } },
                               { $inc: { 'wallet.balance': NumberDecimal('-5000') } });
print('  debit 5,000      -> matched ' + r.matchedCount + ', modified ' + r.modifiedCount + '  (success)');
r = db.customers.updateOne({ _id: who, 'wallet.balance': { $gte: NumberDecimal('99999999') } },
                           { $inc: { 'wallet.balance': NumberDecimal('-99999999') } });
print('  debit 99,999,999 -> matched ' + r.matchedCount + ', modified ' + r.modifiedCount + '  (refused: condition false, nothing changed)');
print('  balance after           : ' + db.customers.findOne({ _id: who }).wallet.balance);
db.customers.updateOne({ _id: who }, { $set: { 'wallet.balance': before } });   // restore for repeatable runs

// ---------------------------------------------------------------------
h('Q7  ARRAY UPDATE OPERATORS: register a new phone, keep only the 5 most recent');
r = db.customers.updateOne({ _id: who }, { $push: { devices: { $each: [{ device_id: 'DEV-NEW-1', os: 'Android', model: 'Tecno Camon 30',
       app_version: '5.2.3', trusted: false }], $slice: -5 } }, $addToSet: { tags: 'upgraded_phone' } });
print('  modified ' + r.modifiedCount + ' -> devices now: ' + db.customers.findOne({ _id: who }).devices.map(d => d.model).join(', '));
db.customers.updateOne({ _id: who }, { $pull: { devices: { device_id: 'DEV-NEW-1' }, tags: 'upgraded_phone' } });   // restore

// ---------------------------------------------------------------------
h('Q8  SCHEMA VALIDATION: flexible, but not lawless');
try {
  db.customers.insertOne({ _id: '08012', name: { first: 'Bad' }, country: 'XX', tier: NumberInt(9), status: 'ACTIVE',
                           wallet: { currency: 'NGN', balance: NumberDecimal('-50') }, kyc: { documents: [] }, created_at: new Date() });
  print('  invalid insert ACCEPTED (unexpected)');
} catch (e) {
  print('  invalid insert REJECTED: ' + e.message.split('\n')[0]);
  const details = (e.errInfo && e.errInfo.details && e.errInfo.details.schemaRulesNotSatisfied) || [];
  details.forEach(d => (d.propertiesNotSatisfied || []).forEach(p => print('     - field "' + p.propertyName + '" failed: ' + p.details.map(x => x.reason).join('; '))));
}
r = db.customers.insertOne({ _id: '2349555000001', name: { first: 'Zara', last: 'New' }, country: 'NG', tier: NumberInt(1), status: 'ACTIVE',
                             wallet: { currency: 'NGN', balance: NumberDecimal('0') }, kyc: { documents: [] }, created_at: new Date(),
                             loyalty: { programme: 'KashPoints', points: 120 } });
print('  valid insert with a brand-new optional field "loyalty" ACCEPTED -> no migration needed (acknowledged: ' + r.acknowledged + ')');
db.customers.deleteOne({ _id: '2349555000001' });

// ---------------------------------------------------------------------
h('Q9  GRAPH TRAVERSAL ($graphLookup): trace where money flowed from a flagged account');
// Fraud team flags 2349100000001. Follow large (>= 100,000) transfers within 24h, up to 5 hops.
const start = db.transactions.findOne({ 'from.msisdn': '2349100000001', amount: { $gte: NumberDecimal('100000') } });
print('  hop 1: ' + start.from.msisdn + ' -> ' + start.to.msisdn + '  ' + start.amount + '  at ' + start.ts.toISOString() + '  (flagged starting transfer)');
show(db.transactions.aggregate([
  { $match: { _id: start._id } },
  { $limit: 1 },
  { $graphLookup: { from: 'transactions', startWith: '$to.msisdn', connectFromField: 'to.msisdn', connectToField: 'from.msisdn',
                    as: 'chain', maxDepth: 4, depthField: 'hop',
                    restrictSearchWithMatch: { type: 'P2P', amount: { $gte: NumberDecimal('100000') },
                                               ts: { $gte: ISODate('2026-10-28T00:00:00Z'), $lt: ISODate('2026-10-29T00:00:00Z') } } } },
  { $unwind: '$chain' }, { $sort: { 'chain.hop': 1, 'chain.ts': 1 } },
  { $project: { _id: 0, hop: { $toInt: { $add: ['$chain.hop', 2] } }, from: '$chain.from.msisdn', to: '$chain.to.msisdn',
                amount: '$chain.amount', at: '$chain.ts', device: '$chain.channel_meta.device_id' } }]));
print('  -> By hop 5 the money is back at the flagged account, and hop 6 is the original transfer again: a CYCLE.');
print('     Each hop is ~11 minutes apart, ~3-4% is skimmed per hop, and every transfer uses ONE shared device:');
print('     classic money-mule ring. Accounts involved:');
show(db.customers.find({ _id: { $regex: '^23491000000' } }, { 'name.last': 1, created_at: 1, tags: 1, 'kyc.documents.verified': 1 }));

// ---------------------------------------------------------------------
h('Q10 BUCKET PATTERN: pre-built monthly statements (one read per statement screen)');
db.transactions.aggregate([
  { $match: { status: 'SUCCESS', type: 'P2P' } },
  { $project: { month: { $dateToString: { format: '%Y-%m', date: '$ts' } }, ts: 1, ref: 1, amount: 1,
                legs: [{ msisdn: '$from.msisdn', dir: 'OUT', other: '$to.name' }, { msisdn: '$to.msisdn', dir: 'IN', other: '$from.name' }] } },
  { $unwind: '$legs' },
  { $sort: { ts: 1 } },
  { $group: { _id: { msisdn: '$legs.msisdn', month: '$month' },
              count: { $sum: 1 },
              total_in:  { $sum: { $cond: [{ $eq: ['$legs.dir', 'IN'] }, '$amount', 0] } },
              total_out: { $sum: { $cond: [{ $eq: ['$legs.dir', 'OUT'] }, '$amount', 0] } },
              entries: { $push: { ts: '$ts', ref: '$ref', dir: '$legs.dir', amount: '$amount', counterparty: '$legs.other' } } } },
  { $merge: { into: 'statements', whenMatched: 'replace' } }]);
print('  statements collection built: ' + db.statements.countDocuments() + ' bucket documents (one per customer per month)');
const st = db.statements.findOne({ '_id.msisdn': '2349000000006', '_id.month': '2026-10' }) ||
           db.statements.findOne({ '_id.msisdn': '2349000000006' });
print('  statement for ' + JSON.stringify(st._id) + ': ' + st.count + ' entries, in ' + st.total_in + ', out ' + st.total_out);
st.entries.slice(0, 4).forEach(e => print('    ' + e.ts.toISOString().slice(0, 16) + '  ' + e.dir.padEnd(3) + '  ' + String(e.amount).padStart(9) + '  ' + e.counterparty));
