'use strict';
// "AI habit check": code decides which criteria are met (exact numbers); a small model (Haiku, else Luna) only orders
// and words them. Every model sentence is checked: criteria must be among the met ones, numbers must come from the
// findings, and advice that contradicts the official guidance is dropped. Anything dropped falls back to fixed text.
// Sends aggregates only (token counts, project names, settings numbers); never conversation content or titles.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),{spawn}=require('node:child_process');

const SRC={claude_cli_local:'Claude Code',claude_aside_local:'Aside Claude',codex_cli_local:'Codex 앱',codex_aside_local:'Aside Codex',grok_aside_local:'Aside Grok',aside_aside_local:'Aside 자체 모델'};
const pct=(a,b)=>b>0?Math.round(100*a/b):0;
const fmt=n=>n>=1e8?(Math.round(n/1e7)/10)+'억':n>=1e4?Math.round(n/1e4)+'만':String(n);

// ---- 1. input: the same aggregates the dashboard shows, plus model mix measured from the index ----
function buildInput({snap,names,indexPath,home=os.homedir(),now=Date.now()}){
  const nm=id=>id==='unknown'?'(프로젝트 없음)':(names&&names[id])||'(이름 없는 폴더)';
  const input={sources:{},weekTop:[],measured:{},settings:{}};
  for(const d of snap.datasets||[]){const e=d.efficiency;if(!e||e.status!=='observed'||!SRC[d.id])continue;
    input.sources[d.id]={name:SRC[d.id],newTokens:e.freshTokens,peakContext:e.peakContext,longShare:pct(e.longSessionContextTokens,e.contextTokens),longCount:e.longSessions,
      rewritePct:pct(e.expiryRewriteTokens,e.freshTokens),expiries:e.cacheExpiries,breakMin:e.expiryMedianGapMinutes,modelSwitches:e.modelSwitches||0,switchTokens:e.modelSwitchRewriteTokens||0,
      inUse:(e.recentSessions||[]).filter(x=>now-Date.parse(x.lastAt)<6*3600e3&&x.lastContext>400000).map(x=>({project:nm(x.project),context:x.lastContext,minutesAgo:Math.round((now-Date.parse(x.lastAt))/60000)}))};}
  const to=snap.period&&snap.period.to;if(to){const from=new Date(Date.parse(to+'T00:00:00Z')-6*864e5).toISOString().slice(0,10);
    for(const d of snap.datasets||[]){if(!SRC[d.id])continue;const m=new Map();for(const r of (d.breakdowns&&d.breakdowns.project)||[]){if(r.date<from||r.date>to||!r.totals)continue;const id=String(r.id).replace(/^project /,'');const o=m.get(id)||{n:0,t:0};o.t+=r.totals.total||0;o.n+=(r.totals.total||0)-(r.totals.cacheRead||0);m.set(id,o);}
      for(const [id,o] of m)if(o.n>0)input.weekTop.push({project:nm(id),source:SRC[d.id],newTokens:o.n,total:o.t,ratio:Math.round(o.t/o.n)});}
    input.weekTop.sort((a,b)=>b.newTokens-a.newTokens);input.weekTop=input.weekTop.slice(0,8);}
  if(indexPath&&fs.existsSync(indexPath)){const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(indexPath,{readOnly:true});
    try{const f30=new Date(now-30*864e5).toISOString().slice(0,10);
      for(const ds of ['claude_cli_local','claude_aside_local']){let fresh=0,auto=0,autoOpus=0,opus=0;const sess=new Map();
        for(const r of db.prepare('SELECT session,model,attribution,input,cacheRead,cacheCreate,total FROM chosen WHERE dataset=? AND day>=?').iterate(ds,f30)){const f=(r.total||0)-(r.cacheRead||0),isOpus=/opus/i.test(String(r.model||''));fresh+=f;if(isOpus)opus+=f;if(r.attribution==='automated'){auto+=f;if(isOpus)autoOpus+=f;}
          const c=(r.input||0)+(r.cacheRead||0)+(r.cacheCreate||0),x=sess.get(r.session)||{n:0,peak:0,opus:0};x.n++;x.peak=Math.max(x.peak,c);if(isOpus)x.opus+=f;sess.set(r.session,x);}
        let so=0,sn=0;for(const x of sess.values())if(x.n<=30&&x.peak<150000&&x.opus>0){so+=x.opus;sn++;}
        if(fresh>0)input.measured[ds]={name:SRC[ds],opusPct:pct(opus,fresh),helperPct:pct(auto,fresh),helperOpusPct:pct(autoOpus,fresh),shortOpusSessions:sn,shortOpusPct:pct(so,fresh)};}}
    finally{db.close();}}
  const rd=p=>{try{return fs.readFileSync(p,'utf8');}catch{return null;}};
  try{const c=JSON.parse(rd(path.join(home,'.aside','u','0','settings.json'))||'{}').compaction;if(c)input.settings.aside={enabled:c.enabled!==false,thresholdPercent:Number(c.thresholdPercent)};}catch{}
  try{const env=JSON.parse(rd(path.join(home,'.claude','settings.json'))||'{}').env||{};const w=Number(env.CLAUDE_CODE_AUTO_COMPACT_WINDOW);if(w>0)input.settings.claudeCompactWindow=w;}catch{}
  const md=rd(path.join(home,'.claude','CLAUDE.md'));if(md!=null)input.settings.claudeMdLines=md.split('\n').length;
  return input;}

// ---- 2. rules: which criteria are met, with the exact numbers that justify them (impact = share of new tokens it touches) ----
function rules(input){const F=[],S=input.sources,M=input.measured,st=input.settings;
  const add=(id,impact,facts,fixed)=>F.push({id,impact,facts,fixed});
  for(const [k,s] of Object.entries(S))for(const u of s.inUse)add('live-'+k,95,{source:s.name,project:u.project,context:u.context,minutesAgo:u.minutesAgo},{criterion:1,title:`지금 쓰는 ${u.project} 대화가 ${fmt(u.context)} 토큰이에요`,why:`${s.name}, ${u.minutesAgo<1?'방금':u.minutesAgo+'분'} 전. 한 번 더 물으면 ${fmt(u.context)} 토큰을 처음부터 다시 읽어요.`,how:'다음 작업은 새 대화에서 시작해요.'});
  for(const [k,m] of Object.entries(M)){
    if(m.helperPct>=30&&m.helperOpusPct*2>=m.helperPct)add('helpers-'+k,m.helperOpusPct,{source:m.name,helperPct:m.helperPct,helperOpusPct:m.helperOpusPct},{criterion:7,title:`${m.name}의 하위 작업은 Sonnet이나 Haiku로`,why:`하위·예약 작업이 새 토큰의 ${m.helperPct}%이고, 그중 Opus로 돈 게 ${m.helperOpusPct}%예요.`,how:'하위 작업을 맡길 때 모델을 Sonnet(조사, 정리)이나 Haiku(단순 확인)로 지정해요.'});
    if(m.shortOpusPct>=15)add('shortopus-'+k,m.shortOpusPct,{source:m.name,shortOpusPct:m.shortOpusPct,shortOpusSessions:m.shortOpusSessions},{criterion:6,title:`${m.name}의 짧은 작업은 Sonnet이나 Haiku로`,why:`요청 30번 이하, 맥락 15만 미만인데 Opus를 쓴 대화가 ${m.shortOpusSessions}개, 새 토큰의 ${m.shortOpusPct}%예요.`,how:'짧은 실행과 단순 작업은 --model sonnet 또는 haiku로 지정하고, 막혔거나 범위가 넓을 때만 Opus를 써요.'});}
  const ca=S.claude_aside_local,cc=S.claude_cli_local;
  if(st.aside&&ca&&ca.peakContext>600000&&(!st.aside.enabled||st.aside.thresholdPercent>50))add('compact-aside',ca.longShare*0.5,{source:ca.name,thresholdPercent:st.aside.thresholdPercent,peakContext:ca.peakContext,longShare:ca.longShare},{criterion:5,title:'Aside 자동 압축을 더 일찍',why:`Aside는 창의 ${st.aside.thresholdPercent}%에서 압축해서 가장 긴 대화가 ${fmt(ca.peakContext)} 토큰까지 갔어요. 긴 대화가 맥락의 ${ca.longShare}%예요.`,how:'Aside 압축 기준을 40만 토큰 근처로 낮춰요. 대신 앞 내용은 요약돼요.'});
  if(st.claudeCompactWindow>400000&&cc&&cc.peakContext>600000)add('compact-cc',cc.longShare*0.5,{source:cc.name,claudeCompactWindow:st.claudeCompactWindow,peakContext:cc.peakContext,longShare:cc.longShare},{criterion:5,title:'Claude Code 자동 압축을 더 일찍',why:`자동 압축 창이 ${fmt(st.claudeCompactWindow)}이라 가장 긴 대화가 ${fmt(cc.peakContext)} 토큰까지 갔어요. 긴 대화가 맥락의 ${cc.longShare}%예요.`,how:'CLAUDE_CODE_AUTO_COMPACT_WINDOW를 40만 이하로 낮추고, 작업이 끝나는 지점에서 /compact <남길 내용>을 써요.'});
  for(const [k,s] of Object.entries(S)){
    if(s.longShare>=50&&!F.some(f=>f.facts.source===s.name&&f.fixed.criterion===5))add('long-'+k,s.longShare*0.4,{source:s.name,longShare:s.longShare,longCount:s.longCount},{criterion:2,title:`${s.name}: 작업이 바뀌면 새 대화로`,why:`40만 토큰 넘는 대화 ${s.longCount}개가 맥락의 ${s.longShare}%예요.`,how:'다른 작업으로 넘어갈 때 /clear(또는 새 대화)로 시작하고, 필요한 내용만 짧게 넘겨요.'});
    if(s.rewritePct>=15)add('break-'+k,s.rewritePct,{source:s.name,rewritePct:s.rewritePct,expiries:s.expiries,breakMin:s.breakMin},{criterion:3,title:`${s.name}: 오래 쉬었으면 새 대화로`,why:`쉬었다 이어 쓴 재저장이 새 토큰의 ${s.rewritePct}%예요(${s.expiries}번${s.breakMin!=null?`, 보통 ${s.breakMin}분 쉰 뒤`:''}).`,how:'오래 쉬었다 돌아오면 이어 쓰거나 압축하지 말고, 새 대화에 필요한 내용만 넘겨요.'});
    if(s.modelSwitches>=3)add('switch-'+k,pct(s.switchTokens,s.newTokens),{source:s.name,modelSwitches:s.modelSwitches,switchTokens:s.switchTokens},{criterion:4,title:`${s.name}: 대화 중간에 모델 바꾸지 않기`,why:`모델을 바꿔 대화 전체를 다시 저장한 게 ${s.modelSwitches}번(${fmt(s.switchTokens)} 토큰)이에요.`,how:'모델과 생각 단계는 대화를 시작할 때 정해요.'});}
  for(const w of input.weekTop)if(w.ratio>=50&&w.total>=1e8)add('reread-'+w.project+w.source,Math.min(20,w.ratio/5),{source:w.source,project:w.project,newTokens:w.newTokens,total:w.total,ratio:w.ratio},{criterion:8,title:`${w.project} 작업의 다시 읽기 줄이기`,why:`이번 주 새 토큰 ${fmt(w.newTokens)}인데 다시 읽은 양까지 ${fmt(w.total)}, 약 ${w.ratio}배예요.`,how:'작업 단위로 대화를 나누고, 필요한 파일과 부분만 지정해서 읽게 해요.'});
  if(st.claudeMdLines>200)add('claudemd',5,{claudeMdLines:st.claudeMdLines},{criterion:9,title:'기본 CLAUDE.md 줄이기',why:`사용자 CLAUDE.md가 ${st.claudeMdLines}줄이에요. 모든 대화에 매번 실려요.`,how:'200줄 안으로 줄이고, 특정 작업용 지시는 필요할 때만 불러오는 스킬로 옮겨요.'});
  return F.sort((a,b)=>b.impact-a.impact);}

// ---- 3. guardrails on model text ----
const BANNED=[
  {re:/(쉬|공백|만료|휴식)[^.。]{0,30}(\/compact|압축)/,unless:/말고|말아|마세요|않|대신 새/,why:'contradicts guidance: compacting after the cache expired is the most expensive case'},
  {re:/5\s*분[^.。]{0,20}캐시|캐시[^.。]{0,20}5\s*분/,why:'cache lifetime differs by tool and plan; not in the input'},
  {re:/(원|달러|\$|USD|비용이\s*\d)/,why:'no cost estimates'},
  {re:/[A-Za-z]+[A-Z][A-Za-z]+Pct|longShare|helperPct|peakContext|rewritePct/,why:'raw field names'}];
function numbersOf(text){const out=[];const re=/(\d[\d,]*(?:\.\d+)?)\s*(억|만|%|배|분|줄|개|번)?/g;let m;while((m=re.exec(text))){let v=Number(m[1].replace(/,/g,''));if(m[2]==='억')v*=1e8;else if(m[2]==='만')v*=1e4;out.push(v);}return out;}
function validate(items,findings){const allowedCrit=new Set(findings.map(f=>f.fixed.criterion)),nums=new Set([15,30,40,50,150000,200,400000,600000,40e4,5,6]);
  for(const f of findings)for(const v of Object.values(f.facts))if(typeof v==='number')nums.add(v);
  const ok=n=>{if(nums.has(n))return true;for(const v of nums)if(v>=1e4&&Math.abs(v-n)/v<0.06)return true;return false;};   // 0.06: "85만" for 852,373, "1.2억" for 1.199억
  const kept=[],dropped=[];
  for(const it of Array.isArray(items)?items:[]){const text=[it&&it.title,it&&it.why,it&&it.how].map(x=>typeof x==='string'?x:'').join(' ');const crit=(Array.isArray(it&&it.criterion)?it.criterion:[]).map(Number);
    let reason=null;if(!it||!it.title||!it.why||!it.how)reason='missing fields';else if(text.length>600)reason='too long';else if(!crit.length||crit.some(c=>!allowedCrit.has(c)))reason='criterion not met';
    else{const bad=numbersOf(text).filter(n=>!ok(n));if(bad.length)reason='numbers not in findings: '+bad.slice(0,3).join(', ');else{const sentences=text.split(/[.。!?\n]/);const b=BANNED.find(x=>sentences.some(s=>x.re.test(s)&&!(x.unless&&x.unless.test(s))));if(b)reason=b.why;}}
    if(reason)dropped.push({title:String(it&&it.title||'').slice(0,80),reason});else kept.push({criterion:crit,title:it.title.trim(),why:it.why.trim(),how:it.how.trim()});}
  return {kept:kept.slice(0,5),dropped};}

// ---- 4. the model call ----
function prompt(findings){return `아래는 한 사람의 AI 토큰 사용 기록을 코드로 점검해 이미 판정한 결과예요(대화 내용 없음, 집계값만).
규칙:
- 아래 항목만 다뤄요. 새 기준을 만들지 말아요.
- 숫자는 facts에 있는 값만 쓰고, 새로 계산하지 말아요. 큰 수는 "85만", "1.2억"처럼 써도 돼요.
- 비용이나 돈은 말하지 말아요. 서로 다른 출처(source)의 숫자를 더하지 말아요.
- 쉬었다 돌아온 뒤 압축하라고 하지 말아요(그때가 가장 비싸요). 캐시 유지 시간을 단정하지 말아요.
할 일: 영향이 큰 순서로 최대 5개를 골라, 각각 한 가지 구체적인 행동으로 써요. 짧고 쉬운 한국어, 존댓말("~해요").
출력: JSON 배열만. [{"criterion":[번호],"title":"...","why":"...","how":"..."}]

항목(코드 판정, 영향 큰 순):
${JSON.stringify(findings.map(f=>({criterion:f.fixed.criterion,facts:f.facts,draft:{title:f.fixed.title,why:f.fixed.why,how:f.fixed.how}})),null,1)}`;}
function which(names){for(const n of names){for(const dir of (process.env.PATH||'').split(path.delimiter)){const p=path.join(dir,n);if(dir&&fs.existsSync(p))return p;}}return null;}
function runCli(exe,args,input,cwd,timeoutMs){return new Promise(res=>{let out='',err='',done=false;const shell=/\.(cmd|bat)$/i.test(exe);
  const p=spawn(exe,args,{cwd,windowsHide:true,shell});const t=setTimeout(()=>{if(!done){done=true;try{p.kill();}catch{}res({ok:false,reason:'timeout'});}},timeoutMs);
  p.stdout.on('data',d=>{out+=d;if(out.length>200000)p.kill();});p.stderr.on('data',d=>{err+=d;if(err.length>200000)err=err.slice(-100000);});
  p.on('error',e=>{if(!done){done=true;clearTimeout(t);res({ok:false,reason:'spawn_failed'});}});
  p.on('close',code=>{if(done)return;done=true;clearTimeout(t);res({ok:code===0,out,reason:code===0?null:'exit_'+code});});
  p.stdin.end(input);});}
function parseArray(text){const a=String(text||'').indexOf('['),b=String(text||'').lastIndexOf(']');if(a<0||b<a)return null;try{const v=JSON.parse(text.slice(a,b+1));return Array.isArray(v)?v:null;}catch{return null;}}
async function askModel(findings,{workDir,home=os.homedir(),timeoutMs=150000}={}){
  fs.mkdirSync(workDir,{recursive:true});const p=prompt(findings);
  const claude=[path.join(home,'.local','bin','claude.exe'),which(['claude.exe','claude.cmd'])].find(x=>x&&fs.existsSync(x));
  if(claude){const r=await runCli(claude,['-p','--model','haiku','--output-format','text','--disallowedTools','Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Task,NotebookEdit'],p,workDir,timeoutMs);const arr=r.ok?parseArray(r.out):null;if(arr)return {model:'Claude Haiku',items:arr};}
  const codex=which(['codex.cmd','codex.exe']);
  if(codex){const r=await runCli(codex,['exec','--model','gpt-6-luna','--skip-git-repo-check','--sandbox','read-only','-'],p,workDir,timeoutMs);const arr=r.ok?parseArray(r.out):null;if(arr)return {model:'GPT-6 Luna',items:arr};}
  return {model:null,items:[]};}

// ---- 5. whole check: model text where it passes, fixed text for anything it dropped or missed ----
async function habitCheck({snap,names,indexPath,workDir,home,useModel=true,now=Date.now()}){
  const input=buildInput({snap,names,indexPath,home,now}),findings=rules(input);
  if(!findings.length)return {at:new Date(now).toISOString(),model:null,items:[],dropped:[],findings:0};
  const ans=useModel?await askModel(findings,{workDir,home}):{model:null,items:[]};
  const {kept,dropped}=validate(ans.items,findings);
  const covered=new Set(kept.flatMap(k=>k.criterion)),items=kept.map(k=>({...k,by:'model'}));
  for(const f of findings){if(items.length>=5)break;if(!covered.has(f.fixed.criterion)){items.push({...f.fixed,criterion:[f.fixed.criterion],by:'rule'});covered.add(f.fixed.criterion);}}
  return {at:new Date(now).toISOString(),model:ans.model,items:items.slice(0,5),dropped,findings:findings.length};}

module.exports={buildInput,rules,validate,habitCheck,BANNED,numbersOf};
