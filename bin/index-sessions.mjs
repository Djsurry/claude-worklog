#!/usr/bin/env node
// Maintain a searchable index of every Claude Code session.
// Usage:
//   node index-sessions.mjs --all              # full (re)build over all history
//   node index-sessions.mjs --since 2026-07-06 # upsert sessions active on/after a date
// Output: ~/.claude/worklog/index/sessions.jsonl (one JSON object per line).
// Deterministic + cheap (no LLM). A per-session `gist` is left null and filled
// lazily by the recall skill when a session is actually surfaced.

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const HOME = os.homedir();
const projectsDir = path.join(HOME, '.claude', 'projects');
const indexPath = path.join(HOME, '.claude', 'worklog', 'index', 'sessions.jsonl');

// --- args ---
const argv = process.argv.slice(2);
let sinceMs = 0;
let mode = 'all';
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--all') mode = 'all';
  else if (argv[i] === '--since') {
    const d = argv[++i];
    sinceMs = new Date(`${d}T00:00:00`).getTime();
    mode = 'since';
  }
}

const FILE_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'Read', 'NotebookEdit']);
const pad = (n) => String(n).padStart(2, '0');
const localDay = (ms) => {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
};
const clip = (s, n) => {
  s = (s || '').replace(/\s+/g, ' ').trim();
  return s.length > n ? s.slice(0, n) : s;
};
function textOf(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content))
    return content.filter((b) => b && b.type === 'text' && typeof b.text === 'string').map((b) => b.text).join('\n');
  return '';
}

function indexFile(full, sessionId) {
  let lines;
  try {
    lines = fs.readFileSync(full, 'utf8').split('\n');
  } catch {
    return null;
  }
  let cwd = null, branch = null, title = null;
  let firstTs = null, lastTs = null, promptCount = 0;
  const files = new Set();
  const promptTexts = [];
  const asstTexts = [];
  for (const line of lines) {
    const l = line.trim();
    if (!l) continue;
    let o;
    try { o = JSON.parse(l); } catch { continue; }
    if (o.cwd && !cwd) cwd = o.cwd;
    if (o.gitBranch) branch = o.gitBranch;
    if (o.type === 'ai-title' && o.aiTitle) title = o.aiTitle;
    const t = o.timestamp ? Date.parse(o.timestamp) : NaN;
    if (!Number.isNaN(t)) {
      if (firstTs === null || t < firstTs) firstTs = t;
      if (lastTs === null || t > lastTs) lastTs = t;
    }
    if (o.type === 'user' && !o.isMeta && !o.isSidechain) {
      const msg = o.message;
      if (msg && typeof msg === 'object' && msg.role === 'user') {
        const txt = textOf(msg.content);
        if (txt && !txt.startsWith('<') && txt.trim()) {
          promptCount++;
          promptTexts.push(txt);
        }
      }
    }
    if (o.type === 'assistant' && o.message && Array.isArray(o.message.content)) {
      for (const b of o.message.content) {
        if (b && b.type === 'tool_use' && FILE_TOOLS.has(b.name) && b.input && b.input.file_path) {
          files.add(path.basename(b.input.file_path));
        }
        // Assistant prose often holds the conceptual phrasing (e.g. "cattle, not pets") that the
        // user later recalls by, so index it too. Skip tool_use/tool_result noise.
        if (b && b.type === 'text' && typeof b.text === 'string' && b.text.trim()) {
          asstTexts.push(b.text);
        }
      }
    }
  }
  if (firstTs === null) return null; // empty / non-conversational file

  // User prompts first (kept generously), then assistant prose. Much higher caps than before:
  // the old 1800-char clip silently dropped later-in-session content (e.g. a "servers as pets"
  // mention past char 1800), which is a common recall miss. grep over the larger index stays fast.
  const userBlob = clip([title, ...promptTexts].join('  ||  '), 9000);
  const asstBlob = clip(asstTexts.join('  '), 7000);
  const blob = asstBlob ? `${userBlob}  ||ASST||  ${asstBlob}` : userBlob;
  const tickets = [...new Set((blob.match(/BES-\d+/g) || []))];
  return {
    session_id: sessionId,
    date: localDay(lastTs),
    repo: cwd ? path.basename(cwd) : null,
    cwd,
    branch: branch || null,
    title: title || null,
    first: new Date(firstTs).toISOString(),
    last: new Date(lastTs).toISOString(),
    prompt_count: promptCount,
    tickets,
    files: [...files].slice(0, 50),
    text: blob, // searchable: title + user prompts, clipped
    gist: null, // lazily filled by recall
  };
}

// --- load existing index (preserve gists) ---
const byId = new Map();
if (fs.existsSync(indexPath)) {
  for (const line of fs.readFileSync(indexPath, 'utf8').split('\n')) {
    const l = line.trim();
    if (!l) continue;
    try { const o = JSON.parse(l); if (o.session_id) byId.set(o.session_id, o); } catch {}
  }
}

// --- scan ---
let scanned = 0, upserted = 0;
let projDirs = [];
try { projDirs = fs.readdirSync(projectsDir); } catch { projDirs = []; }
for (const proj of projDirs) {
  const dir = path.join(projectsDir, proj);
  let entries = [];
  try { entries = fs.readdirSync(dir).filter((f) => f.endsWith('.jsonl')); } catch { continue; }
  for (const f of entries) {
    const full = path.join(dir, f);
    if (mode === 'since') {
      let st; try { st = fs.statSync(full); } catch { continue; }
      if (st.mtimeMs < sinceMs) continue;
    }
    scanned++;
    const sessionId = f.replace(/\.jsonl$/, '');
    const entry = indexFile(full, sessionId);
    if (!entry) continue;
    const prev = byId.get(sessionId);
    if (prev && prev.gist) entry.gist = prev.gist; // keep cached enrichment
    byId.set(sessionId, entry);
    upserted++;
  }
}

// --- write sorted by last activity desc ---
const all = [...byId.values()].sort((a, b) => (b.last || '').localeCompare(a.last || ''));
fs.mkdirSync(path.dirname(indexPath), { recursive: true });
fs.writeFileSync(indexPath, all.map((e) => JSON.stringify(e)).join('\n') + '\n');
process.stderr.write(`indexed ${upserted}/${scanned} scanned, ${all.length} total -> ${indexPath}\n`);
