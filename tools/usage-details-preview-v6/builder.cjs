#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const core = require('./core.cjs');
const client = require('./client.cjs');
const V2CSS = fs.readFileSync(path.join(__dirname, 'v2.css'), 'utf8');
const clean = s => s.replace(/[\u00b7\u318d\u2022]/g, ' / ');
const json = o => JSON.stringify(o).replace(/</g, '\\u003c').replace(/[\u2028\u2029]/g, c => '\\u' + c.charCodeAt(0).toString(16));
function build(base, input) {
  const S = JSON.parse(JSON.stringify(input));
  if (S.schemaVersion !== '1.0' || !Array.isArray(S.datasets) || !/^\d{4}-\d{2}-\d{2}$/.test(S.period?.from || '') || !/^\d{4}-\d{2}-\d{2}$/.test(S.period?.to || '') || S.period.from > S.period.to) throw Error('Invalid snapshot contract / 스냅샷 형식을 확인하세요.');
  if ((Date.parse(S.period.to)-Date.parse(S.period.from))/86400000 > 20000) throw Error('Snapshot horizon too long / 수집 기간을 확인하세요.');
  // Never pass raw labels from upstream into the HTML. IDs remain opaque and are not shown.
  // "Where used" ids come from a fixed list; anything else becomes unknown.
  const APPS = new Set(['unknown','aside','grok_cli','antigravity_cli','claude_vscode','claude_cli','claude_desktop','claude_sdk_cli','claude_sdk_ts','claude_sdk_py','codex_exec','codex_vscode','codex_desktop','codex_cli','codex_in_claude_code']);
  for (const d of S.datasets) for (const row of d.breakdowns?.app || []) { row.id = APPS.has(String(row.id)) ? String(row.id) : 'unknown'; row.label = row.id; }
  // Real folder names are for the owner's own page only (never in the snapshot): opaque key -> short plain name.
  if (S.localNames !== undefined) { const ok = {}; if (S.localNames && typeof S.localNames === 'object') for (const [k, v] of Object.entries(S.localNames)) if (/^[a-f0-9]{16}$/.test(k) && typeof v === 'string' && /^[^\u0000-\u001f<>"|?*]{1,80}$/.test(v)) ok[k] = v; S.localNames = ok; }
  { const a = S.localAside; S.localAside = a && typeof a === 'object' && Number.isFinite(a.thresholdPercent) && a.thresholdPercent > 0 && a.thresholdPercent <= 100 ? { enabled: a.enabled !== false, thresholdPercent: Math.round(a.thresholdPercent) } : null; }
  { const h = S.localHabit, str = (v, n) => typeof v === 'string' ? v.replace(/[\u0000-\u001f]/g, ' ').slice(0, n) : '';
    S.localHabit = h && typeof h === 'object' && Array.isArray(h.items) ? { at: str(h.at, 40), model: ['Claude Haiku', 'GPT-6 Luna'].includes(h.model) ? h.model : null, dropped: Array.isArray(h.dropped) ? h.dropped.length : 0,
      items: h.items.slice(0, 5).map(i => ({ title: str(i && i.title, 160), why: str(i && i.why, 600), how: str(i && i.how, 300), by: i && i.by === 'model' ? 'model' : 'rule' })).filter(i => i.title),
      info: (Array.isArray(h.info) ? h.info : []).slice(0, 8).map(i => ({ title: str(i && i.title, 160), why: str(i && i.why, 400) })).filter(i => i.title), basis: str(h.basis, 400) } : null; }
  S.localHelpers = Array.isArray(S.localHelpers) ? S.localHelpers.filter(x => typeof x === 'string' && /^[a-f0-9]{16}$/.test(x)).slice(0, 200) : [];
  for (const d of S.datasets) for (const dim of ['project','session','model','attribution']) {
    for (const row of d.breakdowns?.[dim] || []) {
      const label = String(row.label || ''), id = String(row.id || '');
      if (/unknown|unattributed|미상|알 수 없|확인 불가/i.test(label) || /^(unknown|unattributed)$/i.test(id) || !label) row.label = 'unknown';
      else if (dim === 'project' || dim === 'session') row.label = dim + ' ' + (/^[a-f0-9]{16}$/.test(id) ? id : crypto.createHash('sha256').update(d.id+'|'+id).digest('hex').slice(0,16));
      else if (dim === 'attribution') row.label = ['unknown','direct','automated'].includes(id) ? id : 'unknown';
      else row.label = /^(?:claude|gpt|o[134]|gemini|grok|codex|auto|default|sonnet|opus|haiku)[a-zA-Z0-9._ /:-]{0,100}$/i.test(label) ? clean(label) : 'unknown';
      row.id = row.label;
    }
  }
  const logoMatch = base.match(/const\s+logos\s*=\s*(\{[^\r\n]*?\});/);
  if (!logoMatch) throw Error('Embedded logos not found / 기존 로고를 찾을 수 없어요.');
  const logos = require('../service-logos.cjs').load(); // Official shared assets also used by the native widget.
  const css = [...base.matchAll(/<style\b[^>]*>[\s\S]*?<\/style>/g)].map(m=>m[0]).join('\n');
  if (!css || /@import|url\(\s*["']?https?:/i.test(css)) throw Error('Offline CSS required / 오프라인 스타일이 필요해요.');
  const sprite = base.match(/<svg class="sprite"[\s\S]*?<\/svg>/)?.[0] || '';
  const brand = base.match(/<div class="brand">([\s\S]*?)<\/div>/)?.[1] || 'UsageGauge';
  const notice = fs.readFileSync(path.resolve(__dirname, '../../NOTICE'), 'utf8');
  const extra = `<style>
.source-controls{display:flex;align-items:center;flex-wrap:wrap;gap:10px 16px;margin:-6px 0 20px;font-size:12px;color:var(--muted)}select{max-width:100%;height:34px;padding:0 28px 0 10px;border:1px solid var(--line);border-radius:5px;background:var(--paper);color:var(--ink)}.source-controls select{max-width:370px}.source-controls .period-tabs{margin-left:auto}.source-controls label{display:flex;align-items:center;gap:8px}.top-meta{flex-wrap:wrap}.language{display:flex;border:1px solid var(--line);border-radius:4px;overflow:hidden}.language button{padding:3px 7px;font-size:12px}.language [aria-pressed=true]{color:var(--brand);background:var(--brand-soft)}.source-controls .text-button{color:var(--warn)}.exact-latest{margin-top:12px;font-size:12px;color:var(--muted);overflow-wrap:anywhere}.exact-latest strong{color:var(--ink);font-weight:500}.chart-tools{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-top:16px}.chart-tools select{height:28px;font-size:12px}.chart-scroll{overflow:auto}.chart-scroll .chart{min-width:500px}.insight-stack{display:grid;gap:20px}.insight-panel{padding:22px 24px}.insight-panel h2{font-size:15px;font-weight:600;margin-bottom:10px}.insight-panel p{font-size:13px;color:var(--muted);margin:8px 0}.insight-panel table{margin-top:15px}.insight-panel th,.insight-panel td{padding:10px 14px}.insight-pair{display:grid;grid-template-columns:1fr 1fr;gap:20px}.empty{padding:28px 0;color:var(--muted);font-size:13px}.commands{background:var(--soft);padding:15px;white-space:pre-wrap;overflow-wrap:anywhere;font:12px/1.8 Consolas,monospace}.source-grid dl,.dialog-body dl{margin:0}.source-grid dt,.dialog-body dt{margin-top:9px;font-weight:500;color:var(--ink)}.source-grid dd,.dialog-body dd{margin:2px 0 8px;overflow-wrap:anywhere}.dialog{max-height:85vh}.dialog-body{max-height:60vh;overflow:auto}.nav{gap:5px}.table-wrap th,.table-wrap td{white-space:normal}.chart-readout{overflow-wrap:anywhere}.token-parts{font-size:12px}.state:before{display:none}.source-list ul{list-style:none;padding:0}.source-list li{margin:6px 0}.status-line{display:block;margin-top:3px;font-size:12px;color:var(--muted)}.provider-tabs{overflow:auto}.provider-tabs button{white-space:nowrap}.quota-name{flex-wrap:wrap}.quota-row .small-label{margin-top:5px;display:block}.topbar{min-height:65px;height:auto;padding-top:10px;padding-bottom:10px}.main-value{white-space:normal;overflow-wrap:anywhere}.small-label{overflow-wrap:anywhere}.footnote{flex-wrap:wrap}@media(max-width:820px){.nav{overflow:auto;gap:14px}.nav button{white-space:nowrap}.insight-pair{grid-template-columns:1fr}.side-bottom{top:12px}.source-controls .period-tabs{margin-left:0}.top-meta{justify-content:space-between}}@media(max-width:640px){.quota-items{grid-template-columns:1fr}.quota-row{border-bottom:1px solid var(--line)!important}.insight-panel{padding:18px 16px}.source-controls{align-items:flex-start}.source-controls label{width:100%;flex-wrap:wrap}.source-controls select{max-width:100%}.metric-row{gap:12px}.main-value{font-size:34px}.secondary-metric strong{font-size:18px}.top-meta>span:first-child{width:100%}}
</style>`;
  const html = `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; font-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><title>UsageGauge 사용량 대시보드</title>${css}${extra}<style>${V2CSS}</style></head><body>${sprite}<a class="skip" href="#main" id="skip"></a><header class="app-header"><div class="brand">${brand}</div><div class="app-tools"><span id="breadcrumb" hidden></span><span id="freshness" hidden></span><div class="language" aria-label="Language / 언어"><button data-lang="ko">한국어</button><button data-lang="en">English</button></div><button class="theme-button" id="theme"></button></div></header><div class="shell"><aside class="sidebar" id="sidebar"><div class="sidebar-sub" id="tagline"></div><nav class="nav" id="nav"></nav><div class="side-bottom"><div class="local-note" id="local-note"></div></div></aside><div class="workspace"><main class="main" id="main"><div class="page-head"><div><h1 id="title"></h1><p id="desc"></p></div><label class="mobile-view"><select id="view-select" aria-label="화면 이동"></select></label><button class="quiet-button" id="scope-button"></button></div><section class="today" id="today" hidden></section><div class="provider-tabs" id="providers" role="group"></div><div class="source-controls" id="controls"></div><div id="view"></div><footer class="footnote" id="footer"></footer></main></div></div><dialog class="dialog" id="detail-dialog" aria-labelledby="dialog-title"><div class="dialog-head"><h2 id="dialog-title"></h2><button class="close-button" id="dialog-close"></button></div><div class="dialog-body" id="dialog-body"></div><div class="dialog-footer"><button class="primary-button" id="dialog-ok"></button></div></dialog><script>'use strict';const SNAPSHOT=${json(S)};const CORE=(${core.toString()})(SNAPSHOT);(${client.toString()})(SNAPSHOT,${json(logos)},${json(notice)},CORE);</script></body></html>`;
  return clean(html);
}
if (require.main === module) {
  const [base, snapshot, out] = process.argv.slice(2);
  if (!base || !snapshot || !out) { console.error('Usage: node builder.cjs INPUT_BASE_HTML INPUT_SNAPSHOT OUTPUT_HTML'); process.exitCode = 1; }
  else { try { if ([base,snapshot].some(p=>path.resolve(p)===path.resolve(out))) throw Error('Output must not overwrite inputs / 입력 파일을 덮어쓸 수 없어요.'); const html = build(fs.readFileSync(base,'utf8'),JSON.parse(fs.readFileSync(snapshot,'utf8'))); fs.writeFileSync(out,html,'utf8'); console.log('Built / 생성 완료: '+path.resolve(out)); } catch (e) { console.error(e.message);process.exitCode=1; } }
}
module.exports = {build};
