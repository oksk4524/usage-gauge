'use strict';
// Indexed collection (--index). Everything lives in one SQLite file:
//   files  : per source file, how far it was read, its identity and its own diagnostics
//   cand   : every parsed request row (several rows may describe the same request)
//   chosen : the one row kept per request after dedup (maintained incrementally: only touched keys are re-decided)
//   aggcache: per dataset, the heavy aggregates (only rebuilt when that dataset's chosen rows changed or the window moved)
// Unchanged files are never read and never loaded into memory.
//
// Dedup rule (order independent and stable over time; written down on purpose):
// - claude_cli_local: the candidate with the largest output wins. Its time is the earliest time among candidates with the
//   same input/cache counts (a streamed answer keeps its first timestamp).
// - *_aside_local: the candidate with the largest total wins (a record only grows while a turn streams).
// - everything else: the copy in the file that started earliest wins (duplicates are exact copies).
// Remaining ties: the file that started earliest (its first request), then file id, then line. A resumed conversation
// that copies old requests into a new file therefore keeps them in the original conversation. (The per-file cache mode
// picks by processing order instead, i.e. the most recently modified file, which moves requests whenever an old file
// is touched.)
const RULES_VERSION='ix-3';   // ix-2: keyed ids, cache-write lifetime columns; ix-3: recent conversations in efficiency
module.exports=function makeIndexed(L){
 const {fs,DatabaseSync,FIELDS,newDiag,addDiag,counts,integer,iso,hash,statSig,headOf,inRoot,readLines,readCodex,parseCodex,parseGrok,CACHE_VERSION,APPEND_ONLY,semantics,efficiencyOf}=L;
 const DIMS=['project','session','model','attribution','app'];
 const COLS=['ck','ln','tail','dataset','provider','key','at','day','hour','project','session','model','attribution','app','pname','cw5m','cw1h',...FIELDS];
 const INT=new Set(['ln','tail','at','hour','cw5m','cw1h',...FIELDS]);
 function open(file,timezone){
  const db=new DatabaseSync(file);try{return prepare(db,timezone);}catch(e){try{db.close();}catch{}throw e;}
 }
 function prepare(db,timezone){
  db.exec('PRAGMA journal_mode=WAL;PRAGMA synchronous=NORMAL;PRAGMA temp_store=MEMORY;CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY,v TEXT);');
  const m0=k=>{const r=db.prepare('SELECT v FROM meta WHERE k=?').get(k);return r?r.v:null;};
  // days or rules changed: drop and rebuild (columns may differ between rule versions)
  // the recorded rule version is not trusted alone: an interrupted upgrade may have left old columns behind
  const colsOf=t=>db.prepare(`PRAGMA table_info(${t})`).all().map(c=>c.name);const exists=t=>!!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(t);
  const stale=['cand','chosen'].some(t=>exists(t)&&!(t==='cand'?COLS:['cw5m','cw1h','dups','conflicts']).every(c=>colsOf(t).includes(c)))||(exists('files')&&!colsOf('files').includes('firstAt'));
  if(stale||m0('tz')!==timezone||m0('rules')!==RULES_VERSION)db.exec('DROP TABLE IF EXISTS cand;DROP TABLE IF EXISTS files;DROP TABLE IF EXISTS chosen;DROP TABLE IF EXISTS aggcache;');
  db.exec(`
   CREATE TABLE IF NOT EXISTS files(ck TEXT PRIMARY KEY,version INTEGER,coverageFrom TEXT,sig TEXT,offset INTEGER,headLen INTEGER,headHash TEXT,diag TEXT,datasets TEXT,maxLn INTEGER,firstAt INTEGER);
   CREATE TABLE IF NOT EXISTS cand(${COLS.map(c=>c+(INT.has(c)?' INTEGER':' TEXT')).join(',')});
   CREATE INDEX IF NOT EXISTS cand_ck ON cand(ck);CREATE INDEX IF NOT EXISTS cand_key ON cand(dataset,key);
   CREATE TABLE IF NOT EXISTS chosen(dataset TEXT,key TEXT,at INTEGER,day TEXT,hour INTEGER,project TEXT,session TEXT,model TEXT,attribution TEXT,app TEXT,cw5m INTEGER,cw1h INTEGER,${FIELDS.map(k=>k+' INTEGER').join(',')},dups INTEGER,conflicts INTEGER,PRIMARY KEY(dataset,key));
   CREATE INDEX IF NOT EXISTS chosen_day ON chosen(dataset,day);
   CREATE TABLE IF NOT EXISTS aggcache(dataset TEXT PRIMARY KEY,win TEXT,v TEXT);`);
  const m=k=>{const r=db.prepare('SELECT v FROM meta WHERE k=?').get(k);return r?r.v:null;};
  const set=db.prepare('INSERT OR REPLACE INTO meta(k,v) VALUES(?,?)');set.run('tz',timezone);set.run('rules',RULES_VERSION);
  return db;
 }
 return async function indexedPass(args){const db=open(args.config.indexPath,args.opt.timezone);
  // whatever happens, the store is rolled back and closed: an open handle would lock the file
  try{return await pass(db,args);}catch(e){try{if(db.isTransaction)db.exec('ROLLBACK');}catch{}throw e;}finally{try{if(db.isOpen)db.close();}catch{}}
 };
 async function pass(db,{all,opt,states,get,from,config,start}){
  const fmt=new Intl.DateTimeFormat('en-CA',{timeZone:opt.timezone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',hourCycle:'h23'});
  const localOf=at=>{const p=Object.fromEntries(fmt.formatToParts(new Date(at)).map(x=>[x.type,x.value]));return [p.year+'-'+p.month+'-'+p.day,Number(p.hour)];};
  db.exec('BEGIN;CREATE TEMP TABLE IF NOT EXISTS seen(ck TEXT PRIMARY KEY);DELETE FROM seen;CREATE TEMP TABLE IF NOT EXISTS aff(dataset TEXT,key TEXT,PRIMARY KEY(dataset,key));DELETE FROM aff;');
  const getFile=db.prepare('SELECT * FROM files WHERE ck=?'),putFile=db.prepare('INSERT OR REPLACE INTO files(ck,version,coverageFrom,sig,offset,headLen,headHash,diag,datasets,maxLn,firstAt) VALUES(?,?,?,?,?,?,?,?,?,?,?)');
  const touchCk=db.prepare('INSERT OR IGNORE INTO aff(dataset,key) SELECT dataset,key FROM cand WHERE ck=?'),touchTail=db.prepare('INSERT OR IGNORE INTO aff(dataset,key) SELECT dataset,key FROM cand WHERE ck=? AND tail=1');
  const delCk=db.prepare('DELETE FROM cand WHERE ck=?'),delTail=db.prepare('DELETE FROM cand WHERE ck=? AND tail=1'),dsOf=db.prepare('SELECT DISTINCT dataset,provider FROM cand WHERE ck=?');
  const firstOf=db.prepare('SELECT MIN(at) a FROM cand WHERE ck=?'),setDs=db.prepare('UPDATE files SET datasets=? WHERE ck=?');
  const ins=db.prepare(`INSERT INTO cand(${COLS.join(',')}) VALUES(${COLS.map(()=>'?').join(',')})`),affIns=db.prepare('INSERT OR IGNORE INTO aff(dataset,key) VALUES(?,?)');
  const insert=(ck,ln,tail,r)=>{const [day,hour]=localOf(r.at);ins.run(ck,ln,tail,r.dataset||null,r.provider||null,r.key,r.at,day,hour,r.project||null,r.session||null,r.model||null,r.attribution||null,r.app||null,r.pname||null,r.cw5m??null,r.cw1h??null,...FIELDS.map(k=>r.count[k]));affIns.run(r.dataset||null,r.key);};
  const markSeen=db.prepare('INSERT OR IGNORE INTO seen(ck) VALUES(?)');
  // a file's start time only moves earlier (pruning old rows must not reshuffle ties)
  const firstAtFor=(ck,prev)=>{const a=firstOf.get(ck).a;return prev!=null&&a!=null?Math.min(prev,a):a??prev??null;};
  let skipped=0,readFiles=0;
  for(const item of all){
   if(Date.now()-start>opt.maxMs||opt.bytes>=opt.maxBytes){skipped++;continue;}
   let temp=newDiag(),cached=false,datasets=null;
   const ck=hash('ix|'+item.kind+'|'+item.file+'|'+JSON.stringify(item.meta));markSeen.run(ck);
   try{
    const row=item.st?getFile.get(ck):null;
    const ok=row&&row.version===CACHE_VERSION[item.kind]&&row.coverageFrom&&row.coverageFrom<=from;
    if(ok&&row.sig&&row.sig===statSig(item.st)){cached=true;temp={...JSON.parse(row.diag),bytesRead:0};datasets=JSON.parse(row.datasets);}
    else{
     readFiles++;const file=inRoot(item.file,item.root),before=fs.statSync(file);if(before.size>1024**3)throw Error('file_too_large');
     if(APPEND_ONLY.has(item.kind)){
      const prevLen=ok&&row.headLen!=null?row.headLen:4096,head=headOf(file,prevLen);
      const inc=ok&&Number.isSafeInteger(row.offset)&&row.offset>0&&row.headLen>0&&head.len===row.headLen&&row.headHash===head.hash&&before.size>=row.offset;
      const part=await readLines(file,item.kind,item.meta,opt,temp,inc?row.offset:0);
      let ln=inc?row.maxLn+1:0;if(inc){touchTail.run(ck);delTail.run(ck);}else{touchCk.run(ck);delCk.run(ck);}
      for(const r of part)insert(ck,ln++,0,r);const maxLn=ln-1;for(const r of part.tail)insert(ck,ln++,1,r);
      if(inc){const nb=temp.bytesRead;temp=addDiag(JSON.parse(row.diag),temp);temp.bytesRead=nb;}
      const after=fs.statSync(file);inRoot(file,item.root);const headNow=headOf(file,head.len);
      const settled=statSig(after)===statSig(before),moved=after.size<before.size||headNow.hash!==head.hash,clean=!moved&&!temp.limitReached;if(moved)temp.changedFiles++;
      // not clean: keep this run's rows but force a full re-read next time
      const h4=clean&&!inc?headOf(file,4096):null;
      putFile.run(ck,CACHE_VERSION[item.kind],from,clean&&settled?statSig(after):null,clean?(inc?row.offset:0)+part.consumed:0,clean?(inc?row.headLen:h4.len):null,clean?(inc?row.headHash:h4.hash):null,JSON.stringify(temp),'[]',Math.max(maxLn,inc?row.maxLn:-1),firstAtFor(ck,inc?row.firstAt:null));
     }else{
      let records;if(item.kind==='codex')records=parseCodex(readCodex(file,opt,temp),item.meta,temp).filter(r=>r.at>=opt.begin&&r.at<=opt.end);
      else if(item.kind==='grok'){const text=fs.readFileSync(file,'utf8');opt.bytes+=Buffer.byteLength(text);temp.bytesRead+=Buffer.byteLength(text);records=parseGrok(JSON.parse(text),item.meta).filter(r=>r.at>=opt.begin&&r.at<=opt.end);}
      else records=await readLines(file,item.kind,item.meta,opt,temp);
      touchCk.run(ck);delCk.run(ck);let ln=0;for(const r of records)insert(ck,ln++,0,r);
      const after=fs.statSync(file);inRoot(file,item.root);const settled=statSig(after)===statSig(before);if(!settled)temp.changedFiles++;
      putFile.run(ck,CACHE_VERSION[item.kind],from,settled&&!temp.limitReached?statSig(after):null,0,null,null,JSON.stringify(temp),'[]',ln-1,firstAtFor(ck,null));
     }
    }
   }catch(e){touchCk.run(ck);delCk.run(ck);db.prepare('DELETE FROM files WHERE ck=?').run(ck);temp.errors++;const code=e.message&&/^[a-z_]+$/.test(e.message)?e.message:'file_read_error';temp.reasons[code]=(temp.reasons[code]||0)+1;}
   if(!datasets){datasets=dsOf.all(ck).map(x=>[x.dataset,x.provider]);setDs.run(JSON.stringify(datasets),ck);}
   // which datasets this file feeds (same rule as the cache mode's "touched" set)
   const ids=item.kind==='aside'?datasets.map(([id,prov])=>get(id,prov,'aside_messages','aside').id):[];if(item.kind!=='aside'&&item.id)ids.push(item.id);
   if(!ids.length&&item.kind==='aside'&&(temp.errors||temp.invalidRecords||temp.oversizeLines))ids.push(get('aside_local','aside','aside_messages','aside').id);
   for(const id of ids){const d=states.get(id).diag;if(item.kind==='aside')d.filesFound++;d.filesRead+=cached?0:1;d.cacheHits+=cached?1:0;for(const k of ['bytesRead','invalidRecords','unmeteredRecords','oversizeLines','changedFiles','errors'])d[k]+=temp[k];d.limitReached ||=temp.limitReached;for(const [k,v]of Object.entries(temp.reasons||{}))d.reasons[k]=(d.reasons[k]||0)+v;}
  }
  // files that disappeared and requests that left the window: only after a complete pass
  if(!skipped){db.exec('INSERT OR IGNORE INTO aff(dataset,key) SELECT dataset,key FROM cand WHERE ck NOT IN (SELECT ck FROM seen);DELETE FROM cand WHERE ck NOT IN (SELECT ck FROM seen);DELETE FROM files WHERE ck NOT IN (SELECT ck FROM seen);');
   db.prepare('INSERT OR IGNORE INTO aff(dataset,key) SELECT dataset,key FROM cand WHERE at<?').run(opt.begin);db.prepare('DELETE FROM cand WHERE at<?').run(opt.begin);}
  // first run or a rebuild: decide every request
  if(!db.prepare('SELECT 1 FROM chosen LIMIT 1').get())db.exec('INSERT OR IGNORE INTO aff(dataset,key) SELECT DISTINCT dataset,key FROM cand');
  const touched=db.prepare('SELECT DISTINCT dataset FROM aff').all().map(r=>r.dataset);
  for(const ds of touched)decide(db,ds);
  const win=opt.from+'|'+opt.to+'|e2',built=new Map();   // e2: efficiency counts model switches
  for(const s of states.values()){if(s.source==='aside_turns')continue;built.set(s.id,buildDataset(db,s,opt,win,touched.includes(s.id)));}
  const names={};for(const r of db.prepare("SELECT project,pname FROM cand WHERE pname IS NOT NULL AND project IS NOT NULL AND project<>'unknown' GROUP BY project").all())names[r.project]=r.pname;
  const touchedKeys=db.prepare('SELECT COUNT(*) n FROM aff').get().n;
  db.exec('COMMIT');
  return {skipped,built,names,stats:{readFiles,touchedKeys,rebuiltDatasets:touched.length}};
 }
 // Re-decide only the requests whose candidate rows changed.
 function decide(db,ds){
  const claude=ds==='claude_cli_local',aside=/_aside_local$/.test(ds||'');
  const ord=(claude?'output DESC,':aside?'total DESC,':'')+'fa,ck,ln';
  const same=claude?'c.input=b.input AND c.cacheRead=b.cacheRead AND c.cacheCreate=b.cacheCreate':'c.ck=b.ck AND c.ln=b.ln';
  const conflict=claude?'NOT(c.input=b.input AND c.cacheRead=b.cacheRead AND c.cacheCreate=b.cacheCreate)':aside?FIELDS.map(k=>`c.${k}>b.${k}`).join(' OR '):FIELDS.map(k=>`c.${k}<>b.${k}`).join(' OR ');
  db.prepare('DELETE FROM chosen WHERE dataset IS ? AND key IN (SELECT key FROM aff WHERE dataset IS ?)').run(ds,ds);
  db.prepare(`INSERT INTO chosen WITH
    c AS (SELECT cand.*,COALESCE(files.firstAt,cand.at) fa FROM cand JOIN aff ON aff.dataset IS cand.dataset AND aff.key=cand.key LEFT JOIN files ON files.ck=cand.ck WHERE cand.dataset IS ?),
    r AS (SELECT c.*,ROW_NUMBER() OVER (PARTITION BY key ORDER BY ${ord}) rn,COUNT(*) OVER (PARTITION BY key) cnt FROM c),
    b AS (SELECT * FROM r WHERE rn=1),
    t AS (SELECT key,at,day,hour FROM (SELECT c.key,c.at,c.day,c.hour,ROW_NUMBER() OVER (PARTITION BY c.key ORDER BY c.at,c.fa,c.ck,c.ln) rt FROM c JOIN b ON b.key=c.key AND ${same}) WHERE rt=1),
    cf AS (SELECT c.key,SUM(CASE WHEN ${conflict} THEN 1 ELSE 0 END) n FROM c JOIN b ON b.key=c.key GROUP BY c.key)
   SELECT b.dataset,b.key,t.at,t.day,t.hour,b.project,b.session,b.model,b.attribution,b.app,b.cw5m,b.cw1h,${FIELDS.map(k=>'b.'+k).join(',')},b.cnt-1,cf.n FROM b JOIN t ON t.key=b.key JOIN cf ON cf.key=b.key`).run(ds);
 }
 function heavy(db,id,opt){
  const inWin='dataset=? AND day BETWEEN ? AND ?',P=[id,opt.from,opt.to],sums=FIELDS.map(k=>`SUM(${k}) ${k}`).join(',');
  const tot=db.prepare(`SELECT ${sums},MAX(at) latest FROM chosen WHERE ${inWin}`).get(...P);
  const daily=db.prepare(`SELECT day,${sums} FROM chosen WHERE ${inWin} GROUP BY day`).all(...P).map(r=>{const c={};for(const k of FIELDS)c[k]=integer(r[k]);return [r.day,c];});
  const breakdowns={};for(const dim of DIMS)breakdowns[dim]=db.prepare(`SELECT day,COALESCE(NULLIF(${dim},''),'unknown') gid,${sums} FROM chosen WHERE ${inWin} GROUP BY day,gid ORDER BY day,gid`).all(...P).map(r=>{const t={};for(const k of FIELDS)t[k]=integer(r[k]);return {date:r.day,id:r.gid,label:r.gid==='unknown'?'unknown':dim==='project'?'project '+r.gid:dim==='session'?'session '+r.gid:r.gid,totals:t};});
  const activity=db.prepare(`SELECT day,hour,attribution,SUM(total) tokens,SUM(records) records FROM chosen WHERE ${inWin} GROUP BY day,hour,attribution ORDER BY day,hour,attribution`).all(...P).map(r=>({date:r.day,hour:r.hour,attribution:r.attribution,tokens:integer(r.tokens),records:integer(r.records)}));
  const kept=[];for(const r of db.prepare(`SELECT session,project,model,at,attribution,cw5m,cw1h,${FIELDS.join(',')} FROM chosen WHERE ${inWin} ORDER BY at,key`).iterate(...P)){const c={};for(const k of FIELDS)c[k]=r[k];kept.push({session:r.session,project:r.project,model:r.model,at:r.at,attribution:r.attribution,cw5m:r.cw5m,cw1h:r.cw1h,count:c});}
  return {tot:{...Object.fromEntries(FIELDS.map(k=>[k,tot[k]])),latest:tot.latest},daily,breakdowns,activity,kept};
 }
 function buildDataset(db,s,opt,win,dirty){
  const {id,provider,source,kind,diag}=s;
  const dc=db.prepare('SELECT COALESCE(SUM(dups),0) d,COALESCE(SUM(conflicts),0) c FROM chosen WHERE dataset=?').get(id);diag.duplicateRecords=integer(dc.d);diag.conflictingRecords=integer(dc.c);
  // heavy aggregates are reused unless this dataset's requests changed or the 30-day window moved
  let H=null;const cached=db.prepare('SELECT win,v FROM aggcache WHERE dataset=?').get(id);
  if(!dirty&&cached&&cached.win===win)H=JSON.parse(cached.v);
  else{const h=heavy(db,id,opt);H={tot:h.tot,daily:h.daily,breakdowns:h.breakdowns,activity:h.activity,efficiency:efficiencyOf(h.kept,kind,source)};db.prepare('INSERT OR REPLACE INTO aggcache(dataset,win,v) VALUES(?,?,?)').run(id,win,JSON.stringify(H));}
  const total=counts();if(H.tot.records)for(const k of FIELDS)total[k]=integer(H.tot[k]);const daily=new Map(H.daily);
  // the rest mirrors dataset() in collect.cjs exactly
  const issues=[];for(const [k,code]of [['invalidRecords','invalid_records'],['unmeteredRecords','unmetered_records'],['conflictingRecords','conflicting_records'],['oversizeLines','oversize_lines'],['changedFiles','file_changed_during_read'],['errors','read_errors'],['limitReached','scan_limit_reached']])if(diag[k])issues.push(code);if(kind==='aside')issues.push('other_apps_not_included');if(kind==='antigravity')issues.push('cache_semantics_not_billing_verified');
  const missing=[];const days=[];for(let d=new Date(opt.from+'T00:00:00Z');d<=new Date(opt.to+'T00:00:00Z');d.setUTCDate(d.getUTCDate()+1)){const date=d.toISOString().slice(0,10),c=daily.get(date);if(!c)missing.push(date);days.push(c?{date,tokens:c.total,...c,coverageStatus:date===opt.to||issues.some(x=>x!=='other_apps_not_included')?'partial':'observed'}:{date,tokens:null,input:null,output:null,cacheRead:null,cacheCreate:null,reasoning:null,records:null,coverageStatus:'missing'});}
  const result={id,provider,source,scope:'this_device',deviceId:'local',accountId:null,capturedAt:new Date().toISOString(),latestEventAt:H.tot.latest?iso(H.tot.latest):null,latestCompleteDate:null,semantics:semantics(kind),coverage:{status:issues.some(x=>x!=='other_apps_not_included')?'partial':total.records?'complete_for_selected_source':'unavailable',issues,filesFound:diag.filesFound,invalidRecords:diag.invalidRecords,unmeteredRecords:diag.unmeteredRecords,duplicateRecords:diag.duplicateRecords,missingDates:missing,comparisonSafe:false,comparisonReason:'no_verified_equal_coverage_history'},totals:total,days,breakdowns:JSON.parse(JSON.stringify(H.breakdowns)),activity:H.activity.map(a=>({...a})),efficiency:JSON.parse(JSON.stringify(H.efficiency)),diagnostics:diag};
  if(total.records===0){for(const key of FIELDS)if(key!=='records')total[key]=null;if(diag.filesFound===0)result.coverage.status='unavailable';}
  return result;
 }
};
