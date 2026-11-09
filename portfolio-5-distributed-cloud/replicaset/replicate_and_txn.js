// Write through the replica set, then run a MULTI-DOCUMENT ACID transaction (needs a replica set).
load('/p5/replicaset/common.js');
const k = db.getSiblingDB('kashlink');
k.wallets.drop(); k.transfers.drop();
const r = k.wallets.insertMany([
  { _id: 'Ada',  msisdn: '2348000000001', balance: NumberDecimal('50000.00') },
  { _id: 'Bola', msisdn: '2348000000002', balance: NumberDecimal('20000.00') }],
  { writeConcern: { w: 'majority', wtimeout: 5000 } });
print('Inserted 2 wallets with writeConcern {w: "majority"}: acknowledged only after 2 of 3 nodes stored them -> ' + r.acknowledged);
print('Write accepted by primary: ' + db.hello().primary);

function transfer(from, to, amount) {
  const s = db.getMongo().startSession();
  const w = s.getDatabase('kashlink').wallets, t = s.getDatabase('kashlink').transfers;
  s.startTransaction({ readConcern: { level: 'snapshot' }, writeConcern: { w: 'majority' } });
  try {
    const debit = w.updateOne({ _id: from, balance: { $gte: NumberDecimal(amount) } }, { $inc: { balance: NumberDecimal('-' + amount) } });
    if (debit.modifiedCount !== 1) throw new Error('Insufficient funds in ' + from);
    w.updateOne({ _id: to }, { $inc: { balance: NumberDecimal(amount) } });
    t.insertOne({ from, to, amount: NumberDecimal(amount), ts: new Date(), status: 'SUCCESS' });
    s.commitTransaction();
    print('  COMMITTED : ' + from + ' -> ' + to + ' ' + amount + ' (debit, credit and transfer record saved together)');
  } catch (e) {
    s.abortTransaction();
    print('  ABORTED   : ' + from + ' -> ' + to + ' ' + amount + ' (' + e.message + ') -> nothing saved');
  } finally { s.endSession(); }
}
print('\nMulti-document transactions across two wallet documents + one transfer document:');
transfer('Ada', 'Bola', '5000.00');
transfer('Ada', 'Bola', '999999.00');
print('Balances now: Ada ' + k.wallets.findOne({ _id: 'Ada' }).balance + ', Bola ' + k.wallets.findOne({ _id: 'Bola' }).balance + ', transfers ' + k.transfers.countDocuments());
