#!/usr/bin/env node
// Extract a compact digest of Claude Code sessions active on a given local-day.
// Usage: node extract-sessions.mjs YYYY-MM-DD
// Prints JSON array to stdout. High-signal only: repo, branch, ai-title, user prompts.
// Deliberately skips tool outputs / assistant bodies to stay small.

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const targetDate = process.argv[2];
if (!/^\d{4}-\d{2}-\d{2}$/.test(targetDate || '')) {
  console.error('usage: extract-sessions.mjs YYYY-MM-DD');
  process.exit(2);
}

// Local-day window (machine TZ, i.e. ET on this laptop).
const dayStart = new Date(`${targetDate}T00:00:00`);
const dayEnd = new Date(dayStart.getTime() + 24 * 3600 * 1000);
const startMs = dayStart.getTime();
const endMs = dayEnd.getTime();

const projectsDir = path.join(os.homedir(), '.claude', 'projects');

function inWindow(ts) {
  if (!ts) return false;
  const t = Date.parse(ts);
  return t >= startMs && t < endMs;
}

function textOf(content) {
  // message.content is either a string or an array of blocks.
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .filter((b) => b && b.type === 'text' && typeof b.text === 'string')
      .map((b) => b.text)
      .join('\n');
  }
  return '';
}

function clip(s, n) {
  s = (s || '').replace(/\s+/g, ' ').trim();
  return s.length > n ? s.slice(0, n) + '…' : s;
}

const sessions = [];

let projectDirs = [];
try {
  projectDirs = fs.readdirSync(projectsDir);
} catch {
  console.log('[]');
  process.exit(0);
}

for (const proj of projectDirs) {
  const dir = path.join(projectsDir, proj);
  let files = [];
  try {
    files = fs.readdirSync(dir).filter((f) => f.endsWith('.jsonl'));
  } catch {
    continue;
  }
  for (const file of files) {
    const full = path.join(dir, file);
    let stat;
    try {
      stat = fs.statSync(full);
    } catch {
      continue;
    }
    // A file last touched before the target day cannot hold target-day events.
    if (stat.mtimeMs < startMs) continue;

    let cwd = null;
    let branch = null;
    let title = null;
    const prompts = [];
    let firstTs = null;
    let lastTs = null;
    let msgCount = 0;

    let lines;
    try {
      lines = fs.readFileSync(full, 'utf8').split('\n');
    } catch {
      continue;
    }

    for (const line of lines) {
      const l = line.trim();
      if (!l) continue;
      let o;
      try {
        o = JSON.parse(l);
      } catch {
        continue;
      }
      if (o.cwd && !cwd) cwd = o.cwd;
      if (o.gitBranch) branch = o.gitBranch;
      // aiTitle is Claude Code's auto-generated session summary; keep the latest.
      if (o.type === 'ai-title' && o.aiTitle) title = o.aiTitle;

      if (!inWindow(o.timestamp)) continue;

      if (o.type === 'user' && !o.isMeta && !o.isSidechain) {
        const msg = o.message;
        const role = msg && typeof msg === 'object' ? msg.role : null;
        if (role === 'user') {
          const t = textOf(msg.content);
          // Skip tool-result-only user turns and slash-command noise.
          // Wider clip: passing "someday" ideas often sit mid-sentence in long messages.
          if (t && !t.startsWith('<') && t.trim()) {
            prompts.push(clip(t, 800));
          }
        }
      }
      const t = Date.parse(o.timestamp);
      if (!Number.isNaN(t)) {
        if (firstTs === null || t < firstTs) firstTs = t;
        if (lastTs === null || t > lastTs) lastTs = t;
        msgCount++;
      }
    }

    // Only include sessions that actually had activity in the window.
    if (msgCount === 0 && prompts.length === 0) continue;

    const repo = cwd ? path.basename(cwd) : proj;
    sessions.push({
      repo,
      cwd,
      branch: branch || null,
      title: title || null,
      prompts: prompts.slice(0, 25),
      prompt_count: prompts.length,
      first: firstTs ? new Date(firstTs).toISOString() : null,
      last: lastTs ? new Date(lastTs).toISOString() : null,
      event_count: msgCount,
      session_file: file,
    });
  }
}

// Newest activity first.
sessions.sort((a, b) => (b.last || '').localeCompare(a.last || ''));
process.stdout.write(JSON.stringify(sessions, null, 2));
