'use strict';
// WRITING.md rule 9: no middle dots (U+00B7, U+2022, U+2219) in strings people see. Scans the macOS app sources, the
// dashboard page code and the habit check. Comments are skipped; escapes such as "\u00b7" in sanitizers are code, not
// text, so only the literal characters count. template.html is excluded: the builder keeps only its CSS, logos and
// brand, never its text. Tests (mac/Tests) are excluded: they are test data.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const ROOT=path.resolve(__dirname,'..','..');const DOTS=/[\u00b7\u2022\u2219]/;
const files=[];const add=(dir,re)=>{const d=path.join(ROOT,dir);if(fs.existsSync(d))for(const f of fs.readdirSync(d))if(re.test(f))files.push(path.join(dir,f));};
add('mac/Sources',/\.swift$/);files.push('tools/usage-details-preview-v6/client.cjs','tools/usage-details-preview-v6/builder.cjs','tools/usage-details-preview-v6/core.cjs','tools/usage-insights-collector/habit-check.cjs','tools/usage-insights-collector/refresh-dashboard.cjs','tools/usage-insights-collector/assemble.cjs');
const strip=line=>{let out='',q=null;for(let i=0;i<line.length;i++){const c=line[i];if(q){out+=c;if(c==='\\'){out+=line[++i]||'';continue;}if(c===q)q=null;continue;}if(c==='/'&&line[i+1]==='/')break;if(c==='"'||c==="'"||c==='`')q=c;out+=c;}return out;};
const bad=[];let scanned=0;
for(const f of files){const p=path.join(ROOT,f);if(!fs.existsSync(p))continue;scanned++;let block=false;
  fs.readFileSync(p,'utf8').split('\n').forEach((l,i)=>{let x=l;if(block){const e=x.indexOf('*/');if(e<0)return;x=x.slice(e+2);block=false;}const s=x.indexOf('/*');if(s>=0&&!/['"`]/.test(x.slice(0,s))){const e=x.indexOf('*/',s+2);if(e<0){block=true;x=x.slice(0,s);}else x=x.slice(0,s)+x.slice(e+2);}
    if(DOTS.test(strip(x)))bad.push(f+':'+(i+1)+': '+l.trim().slice(0,100));});}
assert.ok(scanned>=8,'scanned the user-string files ('+scanned+')');
assert.deepEqual(bad,[],'middle dots in user-visible strings:\n'+bad.join('\n'));
assert.ok(fs.existsSync(path.join(ROOT,'WRITING.md')),'WRITING.md exists');
console.log('PASS no middle dots in user-visible strings ('+scanned+' files)');
console.log('RESULT 1 writing test passed');
