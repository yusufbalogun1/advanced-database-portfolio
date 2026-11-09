// Ask EVERY node directly what role it has and what data it holds (proves replication).
load('/p5/replicaset/common.js');
print('  node            role        transfers  Ada balance  Bola balance');
print('  --------------  ----------  ---------  -----------  ------------');
HOSTS.forEach(h => {
  try {
    const c = direct(h); const hello = c.getDB('admin').runCommand({ hello: 1 });
    const role = hello.isWritablePrimary ? 'PRIMARY' : hello.secondary ? 'SECONDARY' : 'OTHER';
    const k = c.getDB('kashlink');
    const w = id => { const d = k.wallets.findOne({ _id: id }); return d ? d.balance.toString() : '-'; };
    print('  ' + h.padEnd(14) + '  ' + role.padEnd(10) + '  ' + String(k.transfers.countDocuments()).padStart(9) +
          '  ' + w('Ada').padStart(11) + '  ' + w('Bola').padStart(12));
  } catch (e) {
    print('  ' + h.padEnd(14) + '  DOWN        (unreachable)');
  }
});
