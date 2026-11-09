// Try a majority write and a secondary read through the replica-set connection.
load('/p5/replicaset/common.js');
const k = db.getSiblingDB('kashlink');
const label = process.env.KL_NOTE || 'test';
try {
  const t0 = Date.now();
  k.transfers.insertOne({ from: 'Ada', to: 'Bola', amount: NumberDecimal('100.00'), ts: new Date(), note: label },
                        { writeConcern: { w: 'majority', wtimeout: 5000 } });
  k.wallets.updateOne({ _id: 'Ada' }, { $inc: { balance: NumberDecimal('-100.00') } }, { writeConcern: { w: 'majority', wtimeout: 5000 } });
  k.wallets.updateOne({ _id: 'Bola' }, { $inc: { balance: NumberDecimal('100.00') } }, { writeConcern: { w: 'majority', wtimeout: 5000 } });
  print('  WRITE ok   : "' + label + '" accepted by primary ' + db.hello().primary + ' in ' + (Date.now() - t0) + ' ms (majority acknowledged)');
} catch (e) {
  print('  WRITE FAILED: ' + (e.codeName || e.name) + ' - ' + e.message.split('\n')[0].slice(0, 110));
}
try {
  db.getMongo().setReadPref('secondaryPreferred');
  print('  READ ok    : transfers visible = ' + k.transfers.countDocuments() + ' (served by a surviving node; may be slightly stale)');
} catch (e) {
  print('  READ FAILED: ' + e.message.split('\n')[0]);
}
