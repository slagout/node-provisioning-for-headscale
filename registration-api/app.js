const express = require('express');
const cors = require('cors');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const app = express();
app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

const REGISTRY_FILE = process.env.REGISTRY_FILE || '/var/lib/ecosynq/node-registry.json';

function ensureRegistryDir() {
  const dir = path.dirname(REGISTRY_FILE);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

function loadRegistry() {
  ensureRegistryDir();
  if (!fs.existsSync(REGISTRY_FILE)) {
    const fresh = { version: '1.0', nodes: {} };
    fs.writeFileSync(REGISTRY_FILE, JSON.stringify(fresh, null, 2));
    return fresh;
  }

  try {
    return JSON.parse(fs.readFileSync(REGISTRY_FILE, 'utf8'));
  } catch (err) {
    // Fall back to a safe empty schema if the registry file becomes unreadable.
    return { version: '1.0', nodes: {} };
  }
}

function saveRegistry(registry) {
  ensureRegistryDir();
  fs.writeFileSync(REGISTRY_FILE, JSON.stringify(registry, null, 2));
}

function isValidVogonId(vogonId) {
  return /^b58:[a-zA-Z0-9]{20,}$/.test(vogonId);
}

function createProof({ node_name, region, datacenter, role, vogon_id, timestamp }) {
  const canonical = {
    node_name,
    region,
    datacenter,
    role,
    vogon_id,
    timestamp: timestamp || new Date().toISOString(),
    nonce: crypto.randomBytes(16).toString('hex')
  };

  const canonicalString = JSON.stringify(canonical);
  const proofHash = crypto.createHash('sha256').update(canonicalString).digest('hex');

  return { canonical, proofHash };
}

app.post('/api/register-node', (req, res) => {
  const { node_name, region, datacenter, role, vogon_id, timestamp } = req.body || {};

  if (!node_name || !region || !vogon_id) {
    return res.status(400).json({ error: 'Missing required fields: node_name, region, vogon_id' });
  }

  if (!isValidVogonId(vogon_id)) {
    return res.status(400).json({ error: 'Invalid VOGON ID format. Expected b58:<base58>' });
  }

  const registry = loadRegistry();
  const existing = registry.nodes[node_name];

  if (existing) {
    if (existing.vogon_id === vogon_id) {
      return res.json({
        success: true,
        message: 'Already registered',
        hash: existing.hash,
        node_name,
        timestamp: existing.timestamp,
        registered_at: existing.registered_at
      });
    }

    return res.status(409).json({
      error: 'Node already registered to a different wallet. Contact support.'
    });
  }

  const { canonical, proofHash } = createProof({
    node_name,
    region,
    datacenter,
    role,
    vogon_id,
    timestamp
  });

  registry.nodes[node_name] = {
    region,
    datacenter: datacenter || 'unknown',
    role: role || 'witness',
    vogon_id,
    hash: proofHash,
    timestamp: canonical.timestamp,
    registered_at: new Date().toISOString()
  };

  saveRegistry(registry);

  return res.json({
    success: true,
    hash: proofHash,
    node_name,
    vogon_id,
    registered_at: registry.nodes[node_name].registered_at
  });
});

app.get('/api/node/:node_name', (req, res) => {
  const registry = loadRegistry();
  const nodeName = req.params.node_name;
  const node = registry.nodes[nodeName];

  if (!node) {
    return res.status(404).json({ error: 'Node not found' });
  }

  return res.json({
    node_name: nodeName,
    region: node.region,
    role: node.role,
    vogon_id_prefix: `${node.vogon_id.substring(0, 12)}...`,
    registered_at: node.registered_at,
    hash: node.hash
  });
});

app.get('/api/nodes', (_req, res) => {
  const registry = loadRegistry();
  const nodes = Object.entries(registry.nodes).map(([node_name, data]) => ({
    node_name,
    ...data
  }));

  return res.json({
    count: nodes.length,
    nodes
  });
});

const port = Number(process.env.PORT || 3000);
app.listen(port, () => {
  console.log(`EcoSynQ registration API listening on :${port}`);
});
