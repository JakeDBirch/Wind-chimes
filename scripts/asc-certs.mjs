// Lists and deletes Apple Development certificates through the App Store Connect API.
//
// Each TestFlight run on a fresh CI machine makes Xcode create a new cloud-managed
// Development certificate, and Apple caps how many a team can have. The workflow
// snapshots the certificates before archiving and deletes the new one afterwards.
//
//   node scripts/asc-certs.mjs snapshot            # prints the current certificate ids as JSON
//   node scripts/asc-certs.mjs delete-new before.json
//
// Needs ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID in the environment.
import { readFileSync } from 'node:fs';
import { createPrivateKey, sign } from 'node:crypto';

const base = 'https://api.appstoreconnect.apple.com/v1';

function token() {
  const key = createPrivateKey(readFileSync(process.env.ASC_KEY_PATH, 'utf8'));
  const now = Math.floor(Date.now() / 1000);
  const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
  const header = b64({ alg: 'ES256', kid: process.env.ASC_KEY_ID, typ: 'JWT' });
  const payload = b64({ iss: process.env.ASC_ISSUER_ID, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' });
  const signature = sign('sha256', Buffer.from(`${header}.${payload}`), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `${header}.${payload}.${signature}`;
}

async function api(method, path) {
  const res = await fetch(base + path, { method, headers: { Authorization: `Bearer ${token()}` } });
  if (res.status === 204) return null;
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${JSON.stringify(body.errors ?? body)}`);
  return body;
}

async function developmentCertificates() {
  const body = await api('GET', '/certificates?filter[certificateType]=DEVELOPMENT&limit=200');
  return body.data.map((c) => ({ id: c.id, name: c.attributes.displayName ?? c.attributes.name ?? '' }));
}

const [command, arg] = process.argv.slice(2);
if (command === 'snapshot') {
  const certs = await developmentCertificates();
  console.log(JSON.stringify(certs.map((c) => c.id)));
} else if (command === 'delete-new') {
  const before = new Set(JSON.parse(readFileSync(arg, 'utf8')));
  const created = (await developmentCertificates()).filter((c) => !before.has(c.id));
  for (const cert of created) {
    await api('DELETE', `/certificates/${cert.id}`);
    console.log(`Deleted Development certificate ${cert.id} (${cert.name}) created by this run`);
  }
  if (created.length === 0) console.log('No new Development certificates to delete');
} else {
  console.error('usage: asc-certs.mjs snapshot | delete-new <before.json>');
  process.exit(2);
}
