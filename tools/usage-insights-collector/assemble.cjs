'use strict';
// Join saved numeric results only. A failed provider must not block unrelated datasets.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {normalizeDataset}=require('./collect.cjs');
const nil=()=>({input:null,output:null,cacheRead:null,cacheCreate:null,reasoning:null,total:null,records:null});
const stamp=value=>{const d=new Date(value);if(!Number.isFinite(+d))throw Error('invalid_timestamp');return d.toISOString();};
const day=value=>{if(typeof value!=='string'||!/^\d{4}-\d\d-\d\d$/.test(value)||stamp(value+'T00:00:00Z').slice(0,10)!==value)throw Error('invalid_date');return value;};
const count=value=>{if(!Number.isSafeInteger(value)||value<0)throw Error('invalid_count');return value;};
const sum=rows=>rows.reduce((n,r)=>count(n+count(r.tokens)),0);
function saved(file){
 const fallback={rows:[],capturedAt:new Date().toISOString(),issue:'not_collected'};
 if(!file)return fallback;
 try{const st=fs.statSync(file);if(st.size>16*1024**2)throw Error('too_large');const text=fs.readFileSync(file,'utf8').replace(/^\uFEFF/,'').trim();return {rows:text?text.split(/\r?\n/).map(x=>JSON.parse(x)):[],capturedAt:st.mtime.toISOString(),issue:null};}
 catch{return {...fallback,issue:'source_unavailable'};}
}
function unavailableAccount(local,capturedAt){return {id:'codex_account',provider:'codex',source:'codex_account_api',scope:'account',deviceId:null,accountId:null,capturedAt,latestEventAt:null,latestCompleteDate:null,semantics:{id:'codex_reported_total',totalRule:'reported_total',inputIncludesCache:null,outputIncludesReasoning:null,cacheReadIncludedInTotal:null,verified:'source_fields',warnings:['count_components_unavailable']},coverage:{status:'unavailable',issues:['source_unavailable'],filesFound:0,invalidRecords:0,unmeteredRecords:0,duplicateRecords:0,missingDates:[],comparisonSafe:false,comparisonReason:'no_verified_equal_coverage_history'},totals:nil(),days:[],breakdowns:{project:[],session:[],model:[],attribution:[]},activity:[],diagnostics:{status:'source_unavailable'}};}
function account(local,input){
 const codex=input.rows.find(r=>r.service==='Codex'&&r.status==='ok');
 if(!codex)return unavailableAccount(local,input.capturedAt);
 try{
  const raw=codex.data;if(!Array.isArray(raw.daily_values)||!raw.daily_values.length)throw Error('no_data');
  const seen=new Set(),days=raw.daily_values.map(r=>{const date=day(r.date);if(seen.has(date)||date>local.period.to)throw Error('invalid_day');seen.add(date);const n=count(r.tokens);return {date,...nil(),tokens:n,total:n,coverageStatus:'observed'};});
  const total=sum(days);assert.equal(total,raw.lifetime_tokens);assert.equal(total,raw.daily_buckets_sum);assert.equal(days.length,raw.daily_buckets);
  const first=days.map(r=>r.date).sort()[0],missing=[];
  for(let t=Date.parse(first+'T00:00:00Z');t<=Date.parse(local.period.to+'T00:00:00Z');t+=864e5){const date=new Date(t).toISOString().slice(0,10);if(!seen.has(date)){missing.push(date);days.push({date,...nil(),tokens:null,coverageStatus:'missing'});}}
  days.sort((a,b)=>a.date.localeCompare(b.date));
  const result=unavailableAccount(local,codex.capturedAt?stamp(codex.capturedAt):input.capturedAt);
  Object.assign(result,{totals:{...nil(),total},days,diagnostics:{status:'daily_sum_matches_reported_lifetime',serverDayTimezone:'unverified'}});
  result.semantics.warnings.push('server_day_timezone_unverified','capture_time_from_saved_probe');
  Object.assign(result.coverage,{status:'partial',issues:['server_day_timezone_unverified',...(missing.length?['missing_dates']:[])],missingDates:missing});
  return result;
 }catch{return unavailableAccount(local,input.capturedAt);}
}
function assemble(local,inputs){
 assert.equal(local.schemaVersion,'1.0');day(local.period.from);day(local.period.to);assert(local.period.from<=local.period.to);
 for(const d of local.datasets){normalizeDataset(d,local.period.to);for(const rows of Object.values(d.breakdowns))for(const r of rows){if(r.id==='unknown')r.label='unknown';else r.label=r.label.replace(/^Project /,'project ').replace(/^Session /,'session ');}}
 const server=account(local,inputs.codex),q=[];
 // Which signed-in account a saved quota belongs to. The probe emits a one-way key and a masked label only.
 function who(r){const a=r&&r.account;if(!a||typeof a!=='object')return {accountId:null,accountLabel:null};const key=typeof a.key==='string'&&/^[0-9A-F]{8,64}$/i.test(a.key)?'acct_'+a.key.toLowerCase():null,label=typeof a.label==='string'&&/^[^\s@*]{1,3}\*\*\*(@[A-Za-z0-9.-]{1,100})?$/.test(a.label)?a.label:null;return {accountId:key,accountLabel:key?label:null};}
 let current=null;
 { const row=inputs.codex.rows.find(r=>r.service==='Codex'&&r.status==='ok'),a=server.coverage&&server.coverage.status!=='unavailable'?who(row):{accountId:null,accountLabel:null};server.accountId=a.accountId;server.accountLabel=a.accountLabel; }
 function quota(provider,id,window,used,reset,captured,source,model=null){
  assert(Number.isFinite(used)&&used>=0&&used<=100);q.push({id,provider,source,scope:'account',window,model,usedPercent:used,remainingPercent:100-used,remainingCredits:null,resetAt:reset?stamp(reset):null,capturedAt:stamp(captured),unit:'percent',status:'observed',reason:null,...who(current)});
 }
 const failed=new Set();
 for(const r of inputs.limits.rows){if(r.status!=='ok')continue;current=r;try{
  if(r.service==='Codex'){for(const [key,v]of Object.entries(r.data)){if(v&&typeof v==='object'&&typeof v.used_percent==='number')quota('codex','codex_'+key,v.window_seconds===604800?'7d':v.window_seconds===18000?'5h':'account',v.used_percent,v.reset_at?Number(v.reset_at)*1000:null,r.capturedAt,'codex_account_api');}}
  else if(r.service==='Claude'){for(const [key,v]of Object.entries(r.data)){if(v&&typeof v.used_percent==='number')quota('claude','claude_'+key,key==='five_hour'?'5h':key==='seven_day'?'7d':'account',v.used_percent,v.reset_iso,r.capturedAt,'claude_account');}}
  else if(r.service==='Grok')quota('grok','grok_weekly','7d',r.data.used_percent,r.data.reset_iso,r.capturedAt,'grok_account');
 }catch{failed.add(r.service==='Codex'?'codex':r.service==='Claude'?'claude':'grok');}}
 current=null;   // Antigravity's official CLI exposes no account identity
 const ag=inputs.antigravity.rows.find(r=>r.status==='ok');
 if(ag&&Array.isArray(ag.usage_buckets))for(const b of ag.usage_buckets){try{quota('antigravity',b.id,b.window==='weekly'?'7d':b.id.endsWith('-5h')?'5h':'account',100-b.remaining_percent,b.reset_iso,ag.capturedAt,'antigravity_cli_usage',b.id);}catch{failed.add('antigravity');}}
 for(const [provider,source]of Object.entries({codex:'codex_account_api',claude:'claude_account',grok:'grok_account',antigravity:'antigravity_cli_usage'})){
  if(!q.some(r=>r.provider===provider)||failed.has(provider))q.push({id:provider+'_unavailable',provider,source,scope:'account',window:'account',model:null,usedPercent:null,remainingPercent:null,remainingCredits:null,resetAt:null,capturedAt:(provider==='antigravity'?inputs.antigravity:inputs.limits).capturedAt,unit:'percent',status:'unavailable',reason:'source_unavailable'});
 }
 const order=['codex_account','codex_cli_local','codex_aside_local','claude_aside_local','claude_cli_local','grok_aside_local','grok_cli_local','antigravity_local','aside_aside_local','aside_unattributed'];
 const datasets=[server,...local.datasets.filter(d=>d.id!=='codex_account')].sort((a,b)=>order.indexOf(a.id)-order.indexOf(b.id));
 // Local logs carry no account id: every account ever signed in on this PC is mixed together.
 for(const d of datasets)if(d.scope==='this_device'){d.accountId=null;d.semantics=d.semantics||{};const w=Array.isArray(d.semantics.warnings)?d.semantics.warnings:[];if(!w.includes('accounts_not_separable'))w.push('accounts_not_separable');d.semantics.warnings=w;}
 const from=[local.period.from,...server.days.map(r=>r.date)].sort()[0];
 const out={...local,generatedAt:new Date().toISOString(),period:{from,to:local.period.to},datasets,limits:q};
 out.snapshotId='snapshot_'+crypto.createHash('sha256').update(JSON.stringify({datasets,limits:q})).digest('hex').slice(0,16);
 out.notes=[...new Set([...(local.notes||[]),'server_day_timezone_unverified','count_components_unavailable'])];
 out.audit={...local.audit,normalizationVersion:'1.0.2',accountDailyBuckets:server.days.filter(d=>d.tokens!==null).length,accountTotalMatches:server.coverage.status==='unavailable'?null:true,limitWindows:q.length,unavailableProviders:[...new Set(q.filter(x=>x.status==='unavailable').map(x=>x.provider))]};
 for(const d of datasets){const rows=d.days.filter(r=>r.tokens!==null);assert.equal(rows.length?sum(rows):null,d.totals.total);for(const br of Object.values(d.breakdowns)){if(!br.length)continue;assert.equal(br.reduce((n,r)=>count(n+count(r.totals.total)),0),d.totals.total);}if(d.activity.length)assert.equal(d.activity.reduce((n,r)=>count(n+count(r.tokens)),0),d.totals.total);}
 return out;
}
function main(){
 const args=process.argv.slice(2),get=k=>{const i=args.indexOf(k);if(i<0)return null;if(!args[i+1]||args[i+1].startsWith('--'))throw Error('missing_argument');return args[i+1];};
 const lf=get('--local'),of=get('--output');if(!lf||!of)throw Error('local_and_output_required');
 const out=assemble(JSON.parse(fs.readFileSync(lf,'utf8')),{codex:saved(get('--codex')),limits:saved(get('--limits')),antigravity:saved(get('--antigravity-limits'))});
 const data=JSON.stringify(out);assert(!/"(?:content|email|authorization|access_token|refresh_token|password|cwd|filePath)"\s*:/i.test(data));
 const dest=path.resolve(of),tmp=dest+'.tmp-'+process.pid;try{fs.writeFileSync(tmp,data,{flag:'wx'});fs.renameSync(tmp,dest);}finally{try{fs.unlinkSync(tmp);}catch{}}
 assert.equal(JSON.parse(fs.readFileSync(dest,'utf8')).snapshotId,out.snapshotId);
 console.log(JSON.stringify({output:dest,bytes:Buffer.byteLength(data),snapshotId:out.snapshotId,datasets:out.datasets.length,limits:out.limits.length,period:out.period,audit:out.audit}));
}
module.exports={assemble,saved};if(require.main===module)try{main();}catch(e){console.error(JSON.stringify({error:/^[a-z_]{1,64}$/.test(e.message)?e.message:'assembly_failed'}));process.exitCode=1;}
