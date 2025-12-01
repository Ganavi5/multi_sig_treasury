const express = require('express');
const cors = require('cors');
const { SuiClient, getFullnodeUrl } = require('@mysten/sui.js/client');

const app = express();
app.use(cors());
app.use(express.json());

const client = new SuiClient({ url: getFullnodeUrl('testnet') });

// Your IDs
const TREASURY_ID = '0xbabaaa30fe953ffde6da05da0b7394b0a6d4158c0932d7815ad8e7b0634c02e5';
const POLICY_MANAGER_ID = '0x618fae63c1782f155a2cff0f0b39a2b9693b77b2fdbbd182cbfe4782b2210113';
const PACKAGE_ID = '0xf77e98c2a87d82f73955e67114f516d885f2176c7e930488c557b8f1c1d024a1';

// API: Get Treasury
app.get('/api/treasury', async (req, res) => {
  try {
    const treasury = await client.getObject({
      id: TREASURY_ID,
      options: { showContent: true }
    });
    res.json({ status: 'success',  treasury });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// API: Get Policies
app.get('/api/policies', async (req, res) => {
  try {
    const policies = await client.getObject({
      id: POLICY_MANAGER_ID,
      options: { showContent: true }
    });
    res.json({ status: 'success',  policies });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// API: Get Package
app.get('/api/package', async (req, res) => {
  try {
    const pkg = await client.getObject({
      id: PACKAGE_ID,
      options: { showContent: true }
    });
    res.json({ status: 'success',  pkg });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// API: Health check
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date() });
});

// Serve frontend
app.use(express.static('../frontend'));
app.get('/', (req, res) => {
  res.sendFile('../frontend/index.html');
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`🚀 Server running on port ${PORT}`);
});
