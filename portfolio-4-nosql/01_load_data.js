// =====================================================================
// Portfolio 4 - KashLink Mobile Money: MongoDB document model + data load
// Run:  docker exec kashlink-mongo mongosh --quiet kashlink_nosql --file /portfolio/portfolio-4-nosql/01_load_data.js
// Re-running drops and rebuilds the database (reproducible, seeded data).
// =====================================================================

db.dropDatabase();

// ---------- deterministic pseudo-random generator (same data every run) ----------
let seed = 42;
function rnd() { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed);
  t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }
const pick = arr => arr[Math.floor(rnd() * arr.length)];
const randInt = (a, b) => a + Math.floor(rnd() * (b - a + 1));
const dec = n => NumberDecimal(n.toFixed(2));
const pad = (n, w) => String(n).padStart(w, '0');

const COUNTRIES = {
  NG: { currency: 'NGN', prefix: '2349', langs: ['en', 'yo', 'ha', 'ig'],
        cities: { Lagos: [3.35, 6.60], Abuja: [7.49, 9.06], Kano: [8.52, 12.00] },
        first: ['Chinedu','Aisha','Tobi','Ngozi','Yusuf','Kemi','Emeka','Fatima','Seun','Halima'],
        last:  ['Okafor','Bello','Adeyemi','Okeke','Musa','Balogun','Eze','Ibrahim','Nwosu','Lawal'] },
  GH: { currency: 'GHS', prefix: '2335', langs: ['en', 'tw', 'ee'],
        cities: { Accra: [-0.19, 5.60], Kumasi: [-1.62, 6.69] },
        first: ['Kwame','Ama','Kofi','Akosua','Yaw','Abena'], last: ['Mensah','Owusu','Asante','Boateng','Osei','Addo'] },
  UG: { currency: 'UGX', prefix: '2567', langs: ['en', 'lg', 'sw'],
        cities: { Kampala: [32.58, 0.35], Gulu: [32.30, 2.78] },
        first: ['Grace','Joseph','Sarah','Moses','Esther','Brian'], last: ['Namutebi','Okello','Mugisha','Nakato','Kato','Opio'] }
};
const TIER_LIMITS = { 1: { daily: 50000, max_balance: 300000 }, 2: { daily: 200000, max_balance: 1000000 },
                      3: { daily: 2000000, max_balance: 10000000 } };

// ---------------------------------------------------------------------
// 1. customers collection, with schema VALIDATION (flexible but safe)
//    _id = MSISDN: the phone number is the natural key, so profile
//    lookup is a pure key-value access.
// ---------------------------------------------------------------------
db.createCollection('customers', {
  validator: { $jsonSchema: {
    bsonType: 'object',
    required: ['_id', 'name', 'country', 'tier', 'status', 'wallet', 'kyc', 'created_at'],
    properties: {
      _id:     { bsonType: 'string', pattern: '^[0-9]{10,15}$', description: 'MSISDN, digits only' },
      name:    { bsonType: 'object', required: ['first', 'last'] },
      country: { enum: ['NG', 'GH', 'UG'] },
      tier:    { bsonType: 'int', minimum: 1, maximum: 3 },
      status:  { enum: ['ACTIVE', 'SUSPENDED', 'CLOSED'] },
      wallet:  { bsonType: 'object', required: ['currency', 'balance'],
                 properties: { balance: { bsonType: 'decimal', minimum: 0, description: 'no overdraft' } } },
      kyc:     { bsonType: 'object', required: ['documents'],
                 properties: { documents: { bsonType: 'array' } } },
      devices: { bsonType: 'array', maxItems: 5 }
    }
    // additionalProperties is NOT false: new optional fields are allowed (schema flexibility)
  } },
  validationLevel: 'strict', validationAction: 'error'
});

function kycDocs(cc, tier, i) {
  const docs = [];
  const verified = rnd() < 0.85;
  const vdate = new Date(Date.UTC(2025, randInt(0, 11), randInt(1, 28)));
  if (cc === 'NG') {
    docs.push({ type: 'NIN', nin: pad(10000000000 + i, 11), verified, verified_at: verified ? vdate : null });
    if (tier >= 2 && rnd() < 0.9) docs.push({ type: 'BVN', bvn: pad(22000000000 + i, 11), bank: pick(['GTBank','Access','Zenith','UBA']), verified: true });
  } else if (cc === 'GH') {
    docs.push({ type: 'GHANA_CARD', card_number: 'GHA-' + pad(700000000 + i, 9) + '-' + randInt(1, 9),
                expiry: new Date(Date.UTC(randInt(2026, 2031), randInt(0, 11), 1)), verified, verified_at: verified ? vdate : null });
  } else {
    docs.push({ type: 'NATIONAL_ID', nin: 'CM' + pad(90000000 + i, 12), card_number: pad(i, 9),
                district: pick(['Kampala','Wakiso','Gulu']), verified, verified_at: verified ? vdate : null });
  }
  if (tier === 3) docs.push({ type: 'UTILITY_BILL', provider: pick(['Power Co','Water Co']), month: '2025-' + pad(randInt(1, 12), 2), verified: true });
  return docs;
}

const customers = [];
const N_CUST = 2000;
for (let i = 1; i <= N_CUST; i++) {
  const cc = i <= 1400 ? 'NG' : i <= 1800 ? 'GH' : 'UG';
  const C = COUNTRIES[cc];
  const tier = rnd() < 0.6 ? 1 : rnd() < 0.7 ? 2 : 3;
  const doc = {
    _id: C.prefix + pad(i, cc === 'NG' ? 9 : 8),
    name: { first: pick(C.first), last: pick(C.last) },
    dob: new Date(Date.UTC(randInt(1965, 2004), randInt(0, 11), randInt(1, 28))),
    country: cc,
    tier: NumberInt(tier),
    status: rnd() < 0.97 ? 'ACTIVE' : 'SUSPENDED',
    wallet: { wallet_no: 'W' + pad(i, 7), currency: C.currency, balance: dec(randInt(500, TIER_LIMITS[tier].max_balance * 0.8)),
              limits: TIER_LIMITS[tier] },                                       // 1:1 -> embedded
    kyc: { documents: kycDocs(cc, tier, i) },                                    // varies by country -> embedded, polymorphic
    preferences: { language: pick(C.langs), notifications: { sms: true, push: rnd() < 0.6 } },
    created_at: new Date(Date.UTC(2025, randInt(0, 11), randInt(1, 28)))
  };
  // Smartphone users have devices; feature-phone (USSD-only) users simply have no devices field.
  if (rnd() < 0.65) {
    doc.devices = [];
    const n = randInt(1, 3);
    for (let d = 0; d < n; d++) {
      const os = rnd() < 0.85 ? 'Android' : 'iOS';
      doc.devices.push({ device_id: 'DEV-' + i + '-' + d, os,
                         model: os === 'Android' ? pick(['Tecno Spark 10','Infinix Hot 30','Samsung A14','itel A70']) : pick(['iPhone 11','iPhone 13']),
                         app_version: pick(['4.8.2','4.9.0','5.0.1','5.1.0','5.2.3']),
                         trusted: d === 0 });
    }
  }
  // Optional fields appear only where relevant
  if (rnd() < 0.3) doc.beneficiaries = [];      // filled after all customers exist
  if (rnd() < 0.15) doc.tags = [pick(['salary_earner', 'student', 'trader', 'farmer'])];
  if (rnd() < 0.05) doc.merchant = { business_name: doc.name.last + ' Stores', till_number: pad(i, 6), category: pick(['retail','food','transport']) };
  customers.push(doc);
}
// Beneficiaries: small bounded list (max 5), embedded
customers.forEach(c => {
  if (c.beneficiaries) {
    const same = customers.filter(x => x.country === c.country);
    for (let k = 0; k < randInt(1, 4); k++) { const b = pick(same); if (b._id !== c._id) c.beneficiaries.push({ msisdn: b._id, nickname: b.name.first }); }
  }
});
db.customers.insertMany(customers);

// ---------------------------------------------------------------------
// 2. transactions collection: one document per transaction.
//    Party names are SNAPSHOTS (denormalised) so a statement needs no joins.
//    channel_meta has a different shape per channel (polymorphic).
// ---------------------------------------------------------------------
const byCountry = { NG: customers.filter(c => c.country === 'NG'), GH: customers.filter(c => c.country === 'GH'),
                    UG: customers.filter(c => c.country === 'UG') };
const party = c => ({ msisdn: c._id, name: c.name.first + ' ' + c.name.last });
const BILLERS = { NG: [['Lagos Power Distribution','ELECTRICITY'],['StarView TV','TV'],['KashLink Airtime NG','AIRTIME']],
                  GH: [['Accra Water Co.','WATER'],['KashLink Airtime GH','AIRTIME']],
                  UG: [['Kampala Power','ELECTRICITY'],['KashLink Airtime UG','AIRTIME']] };
const FAIL = [['E51','Insufficient funds'],['E61','Daily limit exceeded'],['E55','Wrong PIN'],['E91','Network timeout']];
const start = Date.UTC(2026, 7, 1), span = Date.UTC(2026, 10, 1) - start;   // Aug - Oct 2026

function channelMeta(ch, c, cc, i) {
  const C = COUNTRIES[cc];
  const city = pick(Object.keys(C.cities)); const [lng, lat] = C.cities[city];
  const geo = { type: 'Point', coordinates: [ +(lng + (rnd() - 0.5) * 0.2).toFixed(5), +(lat + (rnd() - 0.5) * 0.2).toFixed(5) ] };
  if (ch === 'USSD')  return { short_code: '*565#', session_id: 'S' + pad(i, 9), network: pick(['MTN','Airtel','Glo']) };
  if (ch === 'APP')   return { device_id: c.devices ? c.devices[0].device_id : 'WEB', os: c.devices ? c.devices[0].os : 'Web',
                               app_version: c.devices ? c.devices[0].app_version : null, ip: '102.89.' + randInt(0, 255) + '.' + randInt(1, 254), city, geo };
  if (ch === 'AGENT') return { agent_code: cc + '-AG-' + pad(randInt(1, 300), 4), city, geo };
  return { partner_id: pick(['PARTNER-ECOM-01','PARTNER-BETTING-07','PARTNER-SCHOOLFEES-03']), client_ip: '41.58.' + randInt(0, 255) + '.' + randInt(1, 254) };
}

const txns = [];
const N_TXN = 30000;
for (let i = 1; i <= N_TXN; i++) {
  const cc = rnd() < 0.7 ? 'NG' : rnd() < 0.67 ? 'GH' : 'UG';
  const from = pick(byCountry[cc]);
  const r = rnd();
  const type = r < 0.55 ? 'P2P' : r < 0.75 ? 'BILL_PAY' : r < 0.9 ? 'CASH_OUT' : 'CASH_IN';
  const channel = (type === 'CASH_IN' || type === 'CASH_OUT') ? 'AGENT' : (rnd() < 0.45 ? 'USSD' : rnd() < 0.85 ? 'APP' : 'API');
  const s = rnd(); const status = s < 0.93 ? 'SUCCESS' : s < 0.98 ? 'FAILED' : 'PENDING';
  const t = { ref: 'TXN-' + pad(i, 8), type, amount: dec(100 + rnd() * 9900),
              currency: COUNTRIES[cc].currency, country: cc, status,
              ts: new Date(start + Math.floor((i / N_TXN) * span)), channel };
  if (type === 'P2P') { let to = pick(byCountry[cc]); if (to._id === from._id) to = byCountry[cc][0]; t.from = party(from); t.to = party(to); }
  else if (type === 'BILL_PAY') { const [bn, bc] = pick(BILLERS[cc]); t.from = party(from); t.biller = { name: bn, category: bc, reference: 'REF-' + i }; }
  else if (type === 'CASH_OUT') { t.from = party(from); }
  else { t.to = party(from); }
  t.channel_meta = channelMeta(channel, from, cc, i);
  if (status === 'FAILED') { const [code, reason] = pick(FAIL); t.failure = { code, reason }; }
  txns.push(t);
}

// ---- A hidden money-mule ring for the graph example (Portfolio 4, query Q8) ----
// Stolen funds enter at M1 and hop quickly through mule accounts, each taking a cut.
const mules = ['2349100000001','2349100000002','2349100000003','2349100000004','2349100000005','2349100000006'];
mules.forEach((m, k) => db.customers.insertOne({ _id: m, name: { first: 'Mule', last: 'Account' + (k + 1) }, country: 'NG',
  tier: NumberInt(1), status: 'ACTIVE', wallet: { wallet_no: 'WM' + k, currency: 'NGN', balance: dec(0) },
  kyc: { documents: [{ type: 'NIN', nin: '0000000000' + k, verified: false }] }, created_at: new Date(Date.UTC(2026, 9, 20)),
  tags: ['new_account'] }));
const ringBase = Date.UTC(2026, 9, 28, 1, 0);   // 28 Oct 2026, 01:00 UTC
[[0, 1, 480000], [1, 2, 470000], [2, 3, 455000], [1, 5, 9500], [3, 4, 440000], [4, 0, 420000]].forEach(([a, b, amt], k) => {
  txns.push({ ref: 'RING-' + k, type: 'P2P', amount: dec(amt), currency: 'NGN', country: 'NG', status: 'SUCCESS',
              ts: new Date(ringBase + k * 11 * 60000), channel: 'APP',
              from: { msisdn: mules[a], name: 'Mule Account' + (a + 1) }, to: { msisdn: mules[b], name: 'Mule Account' + (b + 1) },
              channel_meta: { device_id: 'DEV-SHARED-666', os: 'Android', app_version: '5.2.3', ip: '197.210.66.6', city: 'Lagos',
                              geo: { type: 'Point', coordinates: [3.3500, 6.6000] } } });
});

for (let b = 0; b < txns.length; b += 5000) db.transactions.insertMany(txns.slice(b, b + 5000));

// ---------------------------------------------------------------------
// 3. Indexes needed by the application queries (index evaluation is in 03_indexes.js)
// ---------------------------------------------------------------------
db.transactions.createIndex({ 'channel_meta.geo': '2dsphere' });
db.transactions.createIndex({ ref: 1 }, { unique: true });     // idempotency key, as in Portfolio 3

// ---------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------
print('Loaded KashLink document model:');
print('  customers    : ' + db.customers.countDocuments());
print('  transactions : ' + db.transactions.countDocuments());
print('  customers with devices field   : ' + db.customers.countDocuments({ devices: { $exists: true } }));
print('  customers WITHOUT devices field: ' + db.customers.countDocuments({ devices: { $exists: false } }) + '  (USSD-only users: field simply absent)');
print('  distinct KYC document types    : ' + JSON.stringify(db.customers.distinct('kyc.documents.type')));
print('\nSample customer document (Nigeria, with devices):');
printjson(db.customers.findOne({ country: 'NG', devices: { $exists: true }, beneficiaries: { $exists: true }, tier: 2 }));
print('\nSample customer document (Ghana, different KYC shape):');
printjson(db.customers.findOne({ country: 'GH' }, { name: 1, country: 1, tier: 1, kyc: 1, wallet: 1 }));
print('\nSample transactions (USSD vs APP vs AGENT: different channel_meta shapes):');
['USSD', 'APP', 'AGENT'].forEach(ch => printjson(db.transactions.findOne({ channel: ch, type: { $ne: 'CASH_IN' } }, { _id: 0 })));
