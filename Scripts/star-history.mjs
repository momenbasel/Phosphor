#!/usr/bin/env node
// Renders assets/star-history.svg and assets/star-history-dark.svg from this
// repo's own stargazer timestamps.
//
// star-history.com started serving a "GitHub restricted access to star data"
// placeholder for everyone, so the chart is generated here instead: the
// stargazers API still returns starred_at when called with an authenticated
// token, which every Actions run already has.

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = process.env.GITHUB_REPOSITORY;
const TOKEN = process.env.GITHUB_TOKEN || process.env.TOKEN;
const MAX_POINTS = 220;

const ASSETS = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'assets');

if (!REPO) {
  console.error('GITHUB_REPOSITORY is required (owner/name)');
  process.exit(1);
}
if (!TOKEN) {
  console.error('GITHUB_TOKEN (or TOKEN) is required');
  process.exit(1);
}

const THEMES = {
  light: {
    file: 'star-history.svg',
    bg: '#ffffff',
    border: '#d1d9e0',
    grid: '#e6eaef',
    text: '#1f2328',
    muted: '#59636e',
    accent: '#1f883d',
    fillTop: 0.22,
  },
  dark: {
    file: 'star-history-dark.svg',
    bg: '#0d1117',
    border: '#30363d',
    grid: '#21262d',
    text: '#e6edf3',
    muted: '#8b949e',
    accent: '#3fb950',
    fillTop: 0.3,
  },
};

const FONT =
  "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif";

const stars = await fetchStargazers();
if (stars.length === 0) {
  console.error('no stargazers returned');
  process.exit(1);
}

// Cumulative count over time, then downsample to keep the SVG small.
const series = stars.map((iso, i) => ({ t: Date.parse(iso), v: i + 1 }));
const points = downsample(series, MAX_POINTS);

const W = 760;
const H = 420;
const PLOT = { x: 62, y: 58, w: W - 62 - 24, h: H - 58 - 52 };

const t0 = points[0].t;
const t1 = points[points.length - 1].t;
const span = Math.max(t1 - t0, 1);
const ceiling = niceCeiling(series[series.length - 1].v);

const px = (t) => PLOT.x + ((t - t0) / span) * PLOT.w;
const py = (v) => PLOT.y + PLOT.h - (v / ceiling) * PLOT.h;

const path = points
  .map((p, i) => `${i === 0 ? 'M' : 'L'}${round(px(p.t))} ${round(py(p.v))}`)
  .join(' ');
const area = `${path} L${round(PLOT.x + PLOT.w)} ${PLOT.y + PLOT.h} L${PLOT.x} ${PLOT.y + PLOT.h} Z`;

mkdirSync(ASSETS, { recursive: true });
for (const [name, theme] of Object.entries(THEMES)) {
  writeFileSync(resolve(ASSETS, theme.file), render(theme));
  console.log(`wrote assets/${theme.file} (${name})`);
}
console.log(`${series[series.length - 1].v} stars, ${points.length} plotted points`);

function render(c) {
  const yTicks = ticks(ceiling, 4)
    .map((v) => {
      const y = round(py(v));
      return `  <line x1="${PLOT.x}" y1="${y}" x2="${PLOT.x + PLOT.w}" y2="${y}" stroke="${c.grid}" stroke-width="1"/>
  <text x="${PLOT.x - 10}" y="${y + 4}" fill="${c.muted}" font-family="${FONT}" font-size="11" text-anchor="end">${compact(v)}</text>`;
    })
    .join('\n');

  const xTicks = monthTicks(t0, t1)
    .map(({ t, label }, i, arr) => {
      const anchor = i === 0 ? 'start' : i === arr.length - 1 ? 'end' : 'middle';
      return `  <text x="${round(px(t))}" y="${PLOT.y + PLOT.h + 22}" fill="${c.muted}" font-family="${FONT}" font-size="11" text-anchor="${anchor}">${label}</text>`;
    })
    .join('\n');

  const last = points[points.length - 1];
  const gid = `fill-${c.file.replace(/[^a-z]/g, '')}`;

  return `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" fill="none" xmlns="http://www.w3.org/2000/svg">

  <defs>
    <linearGradient id="${gid}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="${c.accent}" stop-opacity="${c.fillTop}"/>
      <stop offset="100%" stop-color="${c.accent}" stop-opacity="0"/>
    </linearGradient>
  </defs>

  <rect x="0.5" y="0.5" width="${W - 1}" height="${H - 1}" rx="8" fill="${c.bg}" stroke="${c.border}" stroke-width="1"/>

  <text x="24" y="32" fill="${c.text}" font-family="${FONT}" font-size="15" font-weight="600">${escapeXml(REPO)}</text>
  <text x="${W - 24}" y="32" fill="${c.muted}" font-family="${FONT}" font-size="12" text-anchor="end">${compact(last.v)} stars</text>

${yTicks}

  <path d="${area}" fill="url(#${gid})"/>
  <path d="${path}" stroke="${c.accent}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" fill="none"/>
  <circle cx="${round(px(last.t))}" cy="${round(py(last.v))}" r="3.5" fill="${c.accent}"/>

${xTicks}

  <text x="24" y="${H - 14}" fill="${c.muted}" font-family="${FONT}" font-size="10">star history // generated ${new Date().toISOString().slice(0, 10)}</text>
</svg>
`;
}

async function fetchStargazers() {
  const all = [];
  for (let page = 1; page <= 400; page++) {
    const res = await fetch(
      `https://api.github.com/repos/${REPO}/stargazers?per_page=100&page=${page}`,
      {
        headers: {
          Authorization: `Bearer ${TOKEN}`,
          Accept: 'application/vnd.github.star+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'star-history-generator',
        },
      },
    );
    if (!res.ok) {
      console.error(`stargazers page ${page} returned ${res.status}: ${await res.text()}`);
      process.exit(1);
    }
    const batch = await res.json();
    if (batch.length === 0) break;
    for (const s of batch) if (s.starred_at) all.push(s.starred_at);
    if (batch.length < 100) break;
  }
  return all.sort();
}

function downsample(arr, max) {
  if (arr.length <= max) return arr;
  const step = (arr.length - 1) / (max - 1);
  const out = [];
  for (let i = 0; i < max; i++) out.push(arr[Math.round(i * step)]);
  out[out.length - 1] = arr[arr.length - 1];
  return out;
}

function niceCeiling(n) {
  // Leave a little headroom above the latest count without stranding the
  // series in the bottom half of the plot.
  const target = n * 1.06;
  if (target <= 10) return 10;
  const mag = 10 ** Math.floor(Math.log10(target));
  for (const m of [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]) {
    const c = m * mag;
    if (c >= target) return c;
  }
  return 10 * mag;
}

function ticks(ceiling, count) {
  return Array.from({ length: count + 1 }, (_, i) => Math.round((ceiling * i) / count));
}

function pretty(n) {
  return n;
}

function monthTicks(from, to) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const out = [];
  const d = new Date(from);
  d.setUTCDate(1);
  d.setUTCHours(0, 0, 0, 0);
  while (d.getTime() <= to) {
    if (d.getTime() >= from) {
      out.push({ t: d.getTime(), label: `${months[d.getUTCMonth()]} ${d.getUTCFullYear()}` });
    }
    d.setUTCMonth(d.getUTCMonth() + 1);
  }
  // Keep the axis readable on long histories.
  const maxLabels = 7;
  if (out.length > maxLabels) {
    const step = Math.ceil(out.length / maxLabels);
    return out.filter((_, i) => i % step === 0 || i === out.length - 1);
  }
  if (out.length === 0) out.push({ t: from, label: fmt(from) });
  // The first whole month may fall before the first star; label the actual
  // series start so the left edge is not blank.
  if (out[0].t - from > (to - from) * 0.04) out.unshift({ t: from, label: fmt(from) });
  return out;

  function fmt(t) {
    const x = new Date(t);
    return `${months[x.getUTCMonth()]} ${x.getUTCFullYear()}`;
  }
}

function compact(n) {
  if (n >= 1000) return `${(n / 1000).toFixed(n % 1000 === 0 ? 0 : 1)}k`;
  return String(n);
}

function round(n) {
  return Math.round(n * 100) / 100;
}

function escapeXml(s) {
  return s.replace(/[<>&'"]/g, (ch) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;' })[ch]);
}
