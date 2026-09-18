// node verify-deployed.mjs <arc-rpc-url> [address]
// Compares `forge build` output for CrazyGame with the code deployed on chain.
// Masked on both sides: immutable values (set by the constructor) and the trailing CBOR metadata
// (a hash of the source files and settings, which changes with comments such as the licence header).
// Everything that executes must be identical. Needs Node 18+ and nothing else.
import { readFileSync } from 'node:fs';

const [rpc, address = '0x003912feB558f0dFB687B57020fad10f47c6a27f'] = process.argv.slice(2);
if (!rpc) {
  console.error('usage: node verify-deployed.mjs <rpc-url> [address]');
  process.exit(2);
}

const artifact = JSON.parse(readFileSync(new URL('./out/CrazyGame.sol/CrazyGame.json', import.meta.url), 'utf8'));
const local = artifact.deployedBytecode.object.replace(/^0x/, '').toLowerCase();
const spans = Object.values(artifact.deployedBytecode.immutableReferences || {}).flat();

const res = await fetch(rpc, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_getCode', params: [address, 'latest'] }),
});
const { result } = await res.json();
const onchain = String(result || '').replace(/^0x/, '').toLowerCase();
if (!onchain) {
  console.error('no code at ' + address);
  process.exit(1);
}

// The last two bytes of runtime code give the length of the CBOR metadata before them.
const metaStart = (hex) => hex.length / 2 - 2 - parseInt(hex.slice(-4), 16);
function mask(hex) {
  const out = hex.split('');
  for (const s of spans) for (let i = s.start * 2; i < (s.start + s.length) * 2; i++) out[i] = '0';
  for (let i = metaStart(hex) * 2; i < hex.length; i++) out[i] = '0';
  return out.join('');
}

console.log(`on chain: ${onchain.length / 2} bytes   local build: ${local.length / 2} bytes`);
if (onchain.length === local.length && mask(onchain) === mask(local)) {
  console.log('MATCH: the deployed code is this source (immutables and metadata hash masked)');
} else {
  console.log('MISMATCH');
  process.exit(1);
}
