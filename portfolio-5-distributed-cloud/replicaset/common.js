// Shared settings. In Docker the nodes are mongo1..3:27017; KL_HOSTS overrides this for other setups.
const HOSTS = (process.env.KL_HOSTS || 'mongo1:27017,mongo2:27017,mongo3:27017').split(',');
const SET_URI = 'mongodb://' + HOSTS.join(',') + '/kashlink?replicaSet=klrs&serverSelectionTimeoutMS=8000';
function direct(host) {
  return new Mongo('mongodb://' + host + '/?directConnection=true&serverSelectionTimeoutMS=2000&readPreference=secondaryPreferred');
}
