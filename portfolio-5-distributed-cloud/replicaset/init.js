// Initiate the replica set "klrs" with three equal voting members, then wait for an election.
load('/p5/replicaset/common.js');
try {
  rs.status();
  print('Replica set already initiated.');
} catch (e) {
  const cfg = { _id: 'klrs', members: HOSTS.map((h, i) => ({ _id: i, host: h })) };
  printjson(rs.initiate(cfg));
}
for (let i = 0; i < 60; i++) {
  const p = rs.status().members.find(m => m.stateStr === 'PRIMARY');
  if (p) { print('Primary elected: ' + p.name); break; }
  sleep(1000);
}
