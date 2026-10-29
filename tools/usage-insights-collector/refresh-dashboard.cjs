'use strict';
// Scheduled refresh: collect this PC's logs, assemble the snapshot and rebuild the local dashboard page.
// Reads local log files only. No network, no logins, no credential files. Runs as the signed-in user.
// Layout (created by install-dashboard.ps1):
//   %LOCALAPPDATA%\UsageGauge\dashboard\app\...        copied code (this file lives in app\tools\usage-insights-collector)
//   %LOCALAPPDATA%\UsageGauge\dashboard\data\           inputs and outputs (config.json, saved account readings, snapshot)
//   %LOCALAPPDATA%\UsageGauge\dashboard\usage-gauge.html the page the widget opens
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const HOME=path.join(process.env.LOCALAPPDATA||path.join(os.homedir(),'AppData','Local'),'UsageGauge');
const DASH=path.join(HOME,'dashboard'),DATA=path.join(DASH,'data'),APP=path.resolve(__dirname,'..','..');
const LOCK=path.join(DATA,'refresh.lock'),LOG=path.join(DATA,'refresh.log');

function log(entry){try{const line=JSON.stringify({at:new Date().toISOString(),...entry})+'\n';let old='';try{old=fs.readFileSync(LOG,'utf8');}catch{}const keep=old.split('\n').filter(Boolean).slice(-199).join('\n');fs.writeFileSync(LOG,(keep?keep+'\n':'')+line);}catch{}}
function writeAtomic(file,text){const tmp=file+'.tmp-'+process.pid;try{fs.writeFileSync(tmp,text,{flag:'wx'});fs.renameSync(tmp,file);}finally{try{fs.unlinkSync(tmp);}catch{}}}
// one run at a time; a lock older than 20 minutes is from a run that died
function lock(){try{fs.writeFileSync(LOCK,String(process.pid),{flag:'wx'});return true;}catch(e){if(e.code!=='EEXIST')throw e;try{if(Date.now()-fs.statSync(LOCK).mtimeMs>20*60e3){fs.unlinkSync(LOCK);fs.writeFileSync(LOCK,String(process.pid),{flag:'wx'});return true;}}catch{}return false;}}

async function main(){
 fs.mkdirSync(DATA,{recursive:true});
 if(!lock()){log({ok:false,reason:'already_running'});return;}
 const t0=Date.now();
 try{
  const c=require(path.join(APP,'tools','usage-insights-collector','collect.cjs'));
  const {assemble,saved}=require(path.join(APP,'tools','usage-insights-collector','assemble.cjs'));
  const {build}=require(path.join(APP,'tools','usage-details-preview-v6','builder.cjs'));
  let config={};try{config=JSON.parse(fs.readFileSync(path.join(DATA,'config.json'),'utf8'));}catch{}
  const extra=Array.isArray(config.extraAsideRoots)?config.extraAsideRoots.filter(p=>typeof p==='string'&&fs.existsSync(p)):[];
  const local=await c.collect({idKey:c.loadIdKey(path.join(HOME,'collector-id-key')),indexPath:path.join(HOME,'usage-index.sqlite'),extraAsideRoots:extra});
  const input=f=>{const p=path.join(DATA,f);return saved(fs.existsSync(p)?p:null);};
  const snap=assemble(local,{codex:input('codex.jsonl'),limits:input('limits.jsonl'),antigravity:input('antigravity-limits.jsonl')});
  const json=JSON.stringify(snap);
  if(/"(?:content|email|authorization|access_token|refresh_token|password|cwd|filePath)"\s*:/i.test(json))throw Error('sensitive_field_in_snapshot');
  writeAtomic(path.join(DATA,'snapshot.json'),json);
  // real folder names stay on this PC: written beside the page, never into the snapshot
  const names=local.localNames||{};writeAtomic(path.join(DATA,'local-names.json'),JSON.stringify({purpose:'this_pc_dashboard_only',names}));
  const page=build(fs.readFileSync(path.join(APP,'tools','usage-details-preview-v6','template.html'),'utf8'),{...snap,localNames:names});
  writeAtomic(path.join(DASH,'usage-gauge.html'),page);
  const partial=snap.datasets.filter(d=>d.coverage&&d.coverage.status==='partial'&&(d.coverage.issues||[]).includes('scan_limit_reached')).length;
  log({ok:true,ms:Date.now()-t0,bytesRead:local.audit.bytesRead,skippedByBudget:local.audit.filesSkippedByBudget||0,stoppedSources:partial});
 }catch(e){log({ok:false,ms:Date.now()-t0,reason:/^[a-z_]{1,64}$/.test(e.message)?e.message:'refresh_failed'});process.exitCode=1;}
 finally{try{fs.unlinkSync(LOCK);}catch{}}
}
main();
