'use strict';
//
// npm-audit-min-age.js — Supply-chain audit: refuse any package published within
// the last MIN_AGE_DAYS days, evaluated against the resolved entries of a
// package-lock.json file. Fail-closed: unknown publish times (yanked/quarantined
// packages, registry mirror outages) are treated as violations.
//
// Usage:
//   node scripts/npm-audit-min-age.js <path/to/package-lock.json>
//
// Environment:
//   MIN_AGE_DAYS             Minimum age in days (default: 21)
//   NPM_AGE_CACHE            Cache file path (default: /tmp/npm-publish-times-cache.json)
//   NPM_AUDIT_CONCURRENCY    Parallel registry fetches (default: 16)
//   NPM_REGISTRY             Registry base URL (default: https://registry.npmjs.org)
//
// Exit codes:
//   0   PASS — every resolved package is at least MIN_AGE_DAYS old
//   1   FAIL — one or more violations or unknown-publish-time entries
//   2   Audit-internal error (lockfile unreadable, etc.)
//
// Notes:
//   - Workspace-local packages (no node_modules/ in the path) are skipped — they
//     are not registry deps and have no publish time.
//   - Workspace-hoisted deps (under packages/*/node_modules/) ARE audited.
//   - When invoked from a zsh+nvm shell, call node by absolute path
//     (e.g. /Users/<you>/.nvm/versions/node/<ver>/bin/node) to bypass nvm's
//     `node` shell function.
//
const fs = require('fs');
const https = require('https');

const LOCKFILE = process.argv[2];
const MIN_AGE_DAYS = parseInt(process.env.MIN_AGE_DAYS || '21', 10);
const CACHE_FILE = process.env.NPM_AGE_CACHE || '/tmp/npm-publish-times-cache.json';
const CONCURRENCY = parseInt(process.env.NPM_AUDIT_CONCURRENCY || '16', 10);
const REGISTRY = process.env.NPM_REGISTRY || 'https://registry.npmjs.org';

const cutoffMs = Date.now() - MIN_AGE_DAYS * 86400000;
let cache = {};
try { cache = JSON.parse(fs.readFileSync(CACHE_FILE, 'utf8')); } catch {}
function saveCache() { fs.writeFileSync(CACHE_FILE, JSON.stringify(cache)); }

function fetchPackument(name) {
  return new Promise((resolve, reject) => {
    const url = `${REGISTRY}/${name.replace('/', '%2F')}`;
    https.get(url, { headers: { accept: 'application/json' } }, r => {
      let data = '';
      r.on('data', c => data += c);
      r.on('end', () => {
        if (r.statusCode !== 200) return reject(new Error(`HTTP ${r.statusCode} for ${name}`));
        try { resolve(JSON.parse(data)); } catch (e) { reject(e); }
      });
    }).on('error', reject);
  });
}

async function getPublishTime(name, version) {
  const key = `${name}@${version}`;
  if (cache[key]) return cache[key];
  const pkt = await fetchPackument(name);
  if (pkt.time) {
    for (const [v, t] of Object.entries(pkt.time)) cache[`${name}@${v}`] = t;
  }
  return cache[key] || null;
}

function collectEntries(lock) {
  const entries = new Map();
  if (lock.packages) {
    for (const [p, info] of Object.entries(lock.packages)) {
      if (!p || p === '' || info.link) continue;
      // Extract real package name: everything after the last `/node_modules/`
      // segment (or after a leading `node_modules/`). If neither is present,
      // the entry is a pure workspace package and is skipped.
      const lastIdx = p.lastIndexOf('/node_modules/');
      let cleanName;
      if (lastIdx >= 0) {
        cleanName = p.slice(lastIdx + '/node_modules/'.length);
      } else if (p.startsWith('node_modules/')) {
        cleanName = p.slice('node_modules/'.length);
      } else {
        continue;
      }
      if (info.version) entries.set(`${cleanName}@${info.version}`, { name: cleanName, version: info.version });
    }
  } else if (lock.dependencies) {
    const walk = (deps) => {
      for (const [name, info] of Object.entries(deps || {})) {
        if (info.version) entries.set(`${name}@${info.version}`, { name, version: info.version });
        if (info.dependencies) walk(info.dependencies);
      }
    };
    walk(lock.dependencies);
  }
  return [...entries.values()];
}

async function runLimited(items, fn, limit) {
  const out = [];
  let i = 0;
  const workers = Array(Math.min(limit, items.length)).fill(0).map(async () => {
    while (i < items.length) {
      const idx = i++;
      try { out[idx] = await fn(items[idx]); }
      catch (e) { out[idx] = { error: e.message, item: items[idx] }; }
    }
  });
  await Promise.all(workers);
  return out;
}

(async () => {
  const lock = JSON.parse(fs.readFileSync(LOCKFILE, 'utf8'));
  const entries = collectEntries(lock);
  console.log(`Checking ${entries.length} unique packages against cutoff ${new Date(cutoffMs).toISOString().slice(0,10)} (${MIN_AGE_DAYS}d floor)`);

  let checked = 0;
  const results = await runLimited(entries, async ({ name, version }) => {
    const t = await getPublishTime(name, version);
    checked++;
    if (checked % 50 === 0) { process.stderr.write(`  ${checked}/${entries.length}\n`); saveCache(); }
    return { name, version, publishedAt: t };
  }, CONCURRENCY);
  saveCache();

  const violations = [];
  const unknown = [];
  for (const r of results) {
    if (r.error) { unknown.push(r); continue; }
    if (!r.publishedAt) { unknown.push(r); continue; }
    if (new Date(r.publishedAt).getTime() > cutoffMs) violations.push(r);
  }

  console.log('');
  if (violations.length) {
    console.log(`VIOLATIONS (${violations.length}) — packages published within ${MIN_AGE_DAYS}d:`);
    for (const v of violations.sort((a,b) => b.publishedAt.localeCompare(a.publishedAt))) {
      const ageDays = Math.floor((Date.now() - new Date(v.publishedAt)) / 86400000);
      console.log(`  ${v.name}@${v.version}  published ${v.publishedAt}  (${ageDays}d ago)`);
    }
  }
  if (unknown.length) {
    console.log(`\nUNKNOWN PUBLISH TIME (${unknown.length}) — treated as violations under fail-closed policy:`);
    for (const u of unknown) {
      const label = u.item ? `${u.item.name}@${u.item.version}` : (u.name ? `${u.name}@${u.version}` : '?');
      console.log(`  ${label}  ${u.error || '(no time in registry)'}`);
    }
  }

  const totalBad = violations.length + unknown.length;
  if (totalBad === 0) {
    console.log(`PASS: all ${entries.length} packages older than ${MIN_AGE_DAYS}d.`);
    process.exit(0);
  } else {
    console.log(`\nFAIL: ${totalBad} package(s) violate the ${MIN_AGE_DAYS}d minimum-age policy.`);
    process.exit(1);
  }
})().catch(e => { console.error('Audit error:', e); process.exit(2); });
