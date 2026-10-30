'use strict';
// "AI habit check" (cache-aware rules, 2026-10-30). Code decides everything: which items appear, their order and every
// number. A small model (Haiku, else Luna) only rewords the fixed texts; each sentence is checked and anything that
// fails falls back to the fixed text. Sends aggregates only (token counts, source names, settings numbers); never
// conversation content, titles or project names.
//
// Principles (approved by the owner):
//  a) Cache re-reads are good: they cost about 0.1x new input. The cache hit rate (re-read share of input) is shown as
//     a positive number. A high re-read multiple is never a reason to cut re-reads or to split conversations.
//  b) Items are ranked by "한도 부담(요금 기준 추정)" = new input x1 + cache write x(1.25 five-minute, 2 one-hour; 1.25 and
//     a note when the lifetime is not recorded) + cache read x(read ratio) + output x(output/input price ratio).
//  c) Only mechanical cache loss is flagged: (1) a cold restart (cache expired after a long idle, whole context
//     written again), (2) a model switch mid-conversation (whole context written again), (3) auto-compaction rewrites,
//     where threshold advice appears only when a replay of the recorded conversations says which direction helps.
//  d) Model choice is not waste: shown only as a neutral line (모델별 한도 부담 비중), never as advice.
//  e) Positive, cache-preserving wording; each item shows its 부담 and the share of that source's total.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),{spawn}=require('node:child_process');

const SRC={claude_cli_local:'Claude Code',claude_aside_local:'Aside Claude',codex_cli_local:'Codex 앱',codex_aside_local:'Aside Codex',grok_aside_local:'Aside Grok',aside_aside_local:'Aside 자체 모델',grok_cli_local:'Grok CLI',antigravity_local:'Antigravity'};
// no usable cache fields (Grok CLI input already includes the cache, Antigravity cache semantics are not billing-verified)
const UNSUPPORTED=new Set(['grok_cli_local','antigravity_local']);
const ASIDE_SETS=new Set(['claude_aside_local','codex_aside_local','grok_aside_local','aside_aside_local']);
const pct=(a,b)=>b>0?Math.round(100*a/b):0;
const pct1=(a,b)=>b>0?Math.round(1000*a/b)/10:0;
const fmt=n=>{n=Math.round(n);return n>=1e8?(Math.round(n/1e7)/10)+'억':n>=1e4?Math.round(n/1e4)+'만':String(n);};

// ---- price ratios (input = 1). 공개 API 요금 비율 기준, 구독 한도 실제 차감 방식은 비공개라 추정. ----
// Anthropic (Opus, Sonnet, Haiku): output 5x input, cache read 0.1x, cache write 1.25x (5-minute) or 2x (1-hour).
// OpenAI GPT-5 family: output 8x input, cached input 0.1x, no extra charge for cache writes.
// xAI Grok 4 family: output 5x input, cached input 0.25x.
// Other models (for example a newer OpenAI model without a published price here): output 4x and a note, read 0.1x.
const PRICE_NOTE='공개 API 요금 비율 기준, 구독 한도 실제 차감 방식은 비공개라 추정';
const PRICES=[
  {family:'Claude',re:/claude|opus|sonnet|haiku/i,out:5,read:0.1,write5m:1.25,write1h:2},
  {family:'GPT-5',re:/^gpt-5/i,out:8,read:0.1,write:1},
  {family:'Grok 4',re:/^grok-4/i,out:5,read:0.25,write:1}];
const UNKNOWN_OUT=4,UNKNOWN_TTL_WRITE=1.25;
function priceFor(dataset,model){const m=String(model||'');const p=PRICES.find(x=>x.re.test(m));if(p)return {...p,known:true};
  if(/^claude/.test(dataset))return {...PRICES[0],known:true};   // Claude logs with no model name are still Claude prices
  return {family:'?',out:UNKNOWN_OUT,read:0.1,write:/^claude/.test(dataset)?UNKNOWN_TTL_WRITE:1,known:false};}
function modelLabel(id){const s=String(id||'');if(!s||s==='unknown')return '모델 기록 없음';
  let m=s.match(/^claude-([a-z]+)-(\d+)-(\d+)/i);if(m)return m[1][0].toUpperCase()+m[1].slice(1)+' '+m[2]+'.'+m[3];
  m=s.match(/^gpt-([\d.]+)-?(.*)$/i);if(m)return 'GPT-'+m[1]+(m[2]?' '+m[2].split('-').map(w=>w&&w[0].toUpperCase()+w.slice(1)).join(' '):'');
  m=s.match(/^(grok|gemini)-(.+)$/i);if(m)return m[1][0].toUpperCase()+m[1].slice(1)+' '+m[2];return s.slice(0,40);}
const BASIS='한도 부담 = 새 입력×1 + 캐시 저장×1.25(5분)·2(1시간) + 캐시 다시 읽기×0.1 + 출력×모델 비율(Claude 5, GPT-5 8, 모름 4). '+PRICE_NOTE+'. 지난 30일, 출처끼리 더하지 않음.';

// ---- 1. measure one dataset from its request records (sorted by session, then time) ----
const EV={minPrev:20000,idleMin:5,compactPrev:100000};
function writeBurden(r,p){const cw=r.cacheCreate||0;if(p.write!=null)return {b:cw*p.write,unknown:0};const k1=Math.min(cw,r.cw1h||0),k5=Math.min(cw-k1,r.cw5m||0),rest=cw-k1-k5;return {b:k5*p.write5m+k1*p.write1h+rest*UNKNOWN_TTL_WRITE,unknown:rest,k1,k5};}
function analyze(dataset,rows){
  const ctx=r=>(r.input||0)+(r.cacheRead||0)+(r.cacheCreate||0);
  const t={total:0,input:0,write:0,read:0,output:0,inTok:0,readTok:0,writeTok:0,unknownTtl:0,w1h:0,w5m:0},models=new Map(),outUnknown=new Set();
  const cold={n:0,tokens:0,burden:0,gaps:[]},sw={n:0,tokens:0,burden:0},comp={n:0,tokens:0,burden:0,pre:[],post:[],cost:[]},hitGaps=[],missGaps=[];
  const sess=[];let cur=null,prev=null;
  for(const r of rows){const p=priceFor(dataset,r.model),w=writeBurden(r,p),b=(r.input||0)+w.b+(r.cacheRead||0)*p.read+(r.output||0)*p.out;r._b=b;r._p=p;r._w=w.b;
    t.total+=b;t.input+=r.input||0;t.write+=w.b;t.read+=(r.cacheRead||0)*p.read;t.output+=(r.output||0)*p.out;t.inTok+=r.input||0;t.readTok+=r.cacheRead||0;t.writeTok+=r.cacheCreate||0;t.unknownTtl+=w.unknown;t.w1h+=w.k1||0;t.w5m+=w.k5||0;
    if(!p.known)outUnknown.add(modelLabel(r.model));const ml=modelLabel(r.model);models.set(ml,(models.get(ml)||0)+b);
    if(!cur||cur.id!==r.session){cur={id:r.session,rows:[]};sess.push(cur);prev=null;}cur.rows.push(r);
    if(prev&&r.session&&r.session!=='unknown'){const pc=ctx(prev),c=ctx(r),gap=(r.at-prev.at)/60000,same=!(r.model&&prev.model&&r.model!=='unknown'&&prev.model!=='unknown'&&r.model!==prev.model),rew=(r.input||0)+(r.cacheCreate||0),rb=(r.input||0)+r._w;r._kind=null;
      if(pc>=EV.minPrev){
        if((r.cacheRead||0)>=pc*0.5){if(same)hitGaps.push(gap);}
        else if(rew>=pc*0.5){if(!same){sw.n++;sw.tokens+=rew;sw.burden+=rb;r._kind='switch';}else{missGaps.push(gap);if(gap>=EV.idleMin){cold.n++;cold.tokens+=rew;cold.burden+=rb;cold.gaps.push(gap);r._kind='cold';}}}
        else if(same&&c<pc*0.5&&pc>=EV.compactPrev){comp.n++;comp.tokens+=rew;comp.burden+=rb;comp.pre.push(pc);comp.post.push(c);comp.cost.push(rb);r._kind='compact';}}}
    prev=r;}
  const med=a=>{if(!a.length)return null;const s=[...a].sort((x,y)=>x-y);return s[Math.floor(s.length/2)];};
  // cache lifetime: recorded (1-hour / 5-minute writes) first, else measured: the last 5-minute window, counted from 0,
  // where re-reads after that idle gap still outnumber full re-writes (gaps under 5 minutes say nothing about it)
  let lifetime=null,lifeFrom=null;if(t.w1h>t.writeTok*0.5){lifetime=60;lifeFrom='recorded';}else if(t.w5m>t.writeTok*0.5){lifetime=5;lifeFrom='recorded';}
  else{for(let m=10;m<=180;m+=5){const h=hitGaps.filter(g=>g>=m-5&&g<m).length,x=missGaps.filter(g=>g>=m-5&&g<m).length;if(h+x<3)continue;if(h>=x)lifetime=m;else break;}if(lifetime!=null)lifeFrom='measured';}
  const byModel=[...models].filter(([,b])=>b>0).sort((a,b)=>b[1]-a[1]).map(([label,b])=>({label,share:pct(b,t.total)}));
  const readRatio=rows.length?rows[0]._p.read:0.1;
  return {total:t.total,parts:{input:t.input,write:t.write,read:t.read,output:t.output},hitPct:pct(t.readTok,t.readTok+t.inTok+t.writeTok),readRatio,
    ttlUnknown:t.writeTok>0&&t.unknownTtl>t.writeTok*0.5&&/^claude/.test(dataset),outUnknown:[...outUnknown],byModel,lifetime,lifeFrom,
    cold:{n:cold.n,tokens:cold.tokens,burden:cold.burden,medianGap:cold.gaps.length?Math.round(med(cold.gaps)):null},switch:sw,
    compact:{n:comp.n,tokens:comp.tokens,burden:comp.burden,pre:med(comp.pre),post:med(comp.post),cost:med(comp.cost)},sessions:sess};}

// Replays the recorded conversations with a different compaction point: context grows by the recorded steps, a
// compaction drops it to the measured post-compaction size and costs the measured rewrite plus one full read of the
// conversation for the summary call (that call is not in the records). Every request reads its context from cache.
function replay(a,T){let total=0,n=0;const B=a.compact.post,C=a.compact.cost,read=a.readRatio;
  for(const s of a.sessions){const ctx=r=>(r.input||0)+(r.cacheRead||0)+(r.cacheCreate||0);let c=ctx(s.rows[0]);if(c>T){n++;total+=C+read*c;c=B;}total+=read*c;
    for(let i=1;i<s.rows.length;i++){const r=s.rows[i],d=r._kind?0:Math.max(0,ctx(r)-ctx(s.rows[i-1]));c+=d;if(c>T){n++;total+=C+read*c;c=B;}total+=read*c;}}
  return {total,n};}
// The replay does not see the extra reading an agent does after each summary, so candidates stop at half the window.
const COMPACT_CANDIDATES=[50,60,70,80,90,95];
function compactionCurve(a,setting){if(!setting||a.compact.n<3||!a.compact.pre||!a.compact.post||a.compact.post>=a.compact.pre)return null;
  const T=a.compact.pre,base=replay(a,T),cand=[];
  if(setting.percent){for(const q of COMPACT_CANDIDATES)if(q!==setting.percent)cand.push({label:q,T:T*q/setting.percent});}
  else for(const f of [0.6,0.7,0.8,0.9,1.1])cand.push({label:Math.round(T*f/1e4)*1e4,T:T*f});
  const results=cand.filter(c=>c.T>a.compact.post*1.5).map(c=>{const r=replay(a,c.T),save=base.total-r.total;return {label:c.label,lower:c.T<T,n:r.n,save,saveShare:pct1(save,a.total)};});
  return results.length?{current:setting.percent||Math.round(T/1e4)*1e4,unit:setting.percent?'%':'tokens',replayCompactions:base.n,results}:null;}
// One setting can cover several sources (Aside's point applies to every Aside model): pick the gentlest change that keeps
// at least 80% of each source's best saving and makes no source worse; null when nothing saves 3% of a source's total.
function pickCompaction(curves){const labels=[...new Set(curves.flatMap(c=>c.results.map(r=>r.label)))],cur=curves[0].current;
  const at=(c,l)=>c.results.find(r=>r.label===l),best=c=>Math.max(0,...c.results.map(r=>r.save));
  const ok=labels.filter(l=>curves.every(c=>at(c,l)&&at(c,l).save>=0)&&curves.some(c=>at(c,l).saveShare>=THRESH.compactSave));
  if(!ok.length)return null;
  const good=ok.filter(l=>curves.every(c=>best(c)<=0||at(c,l).save>=best(c)*0.8));
  const near=l=>Math.abs((typeof l==='number'?l:0)-cur);
  const pick=(good.length?good:ok).sort((x,y)=>near(x)-near(y))[0];
  return {pick,lower:at(curves[0],pick).lower,per:curves.map(c=>({...at(c,pick)}))};}

// ---- 2. input: per source totals, events and settings (index = this PC's request records, last 30 days) ----
function buildInput({snap,names,indexPath,home=os.homedir(),now=Date.now()}){
  const input={sources:{},excluded:[],settings:{},basis:BASIS};
  const rd=p=>{try{return fs.readFileSync(p,'utf8');}catch{return null;}};
  try{const c=JSON.parse(rd(path.join(home,'.aside','u','0','settings.json'))||'{}').compaction;if(c)input.settings.aside={enabled:c.enabled!==false,thresholdPercent:Number(c.thresholdPercent)};}catch{}
  try{const env=JSON.parse(rd(path.join(home,'.claude','settings.json'))||'{}').env||{};const w=Number(env.CLAUDE_CODE_AUTO_COMPACT_WINDOW);if(w>0)input.settings.claudeCompactWindow=w;}catch{}
  const present=new Set((snap&&snap.datasets||[]).filter(d=>d.totals&&d.totals.records>0).map(d=>d.id));
  for(const id of present)if(UNSUPPORTED.has(id)||((snap.datasets.find(d=>d.id===id).totals||{}).cacheRead==null&&SRC[id]))input.excluded.push(SRC[id]||id);
  if(!indexPath||!fs.existsSync(indexPath))return input;
  const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(indexPath,{readOnly:true});
  try{const f30=new Date(now-30*864e5).toISOString().slice(0,10),by=new Map();
    for(const r of db.prepare('SELECT dataset,session,model,at,input,output,cacheRead,cacheCreate,cw5m,cw1h FROM chosen WHERE day>=? ORDER BY dataset,session,at,key').iterate(f30)){
      if(!SRC[r.dataset])continue;if(UNSUPPORTED.has(r.dataset)){if(!input.excluded.includes(SRC[r.dataset]))input.excluded.push(SRC[r.dataset]);continue;}
      if(!by.has(r.dataset))by.set(r.dataset,[]);by.get(r.dataset).push({...r});}
    for(const [ds,rows] of by){const a=analyze(ds,rows);if(!(a.total>0))continue;
      const st=input.settings,setting=ASIDE_SETS.has(ds)?(st.aside&&st.aside.enabled&&st.aside.thresholdPercent>0?{percent:Math.round(st.aside.thresholdPercent)}:null):ds==='claude_cli_local'&&st.claudeCompactWindow?{tokens:st.claudeCompactWindow}:null;
      const curve=compactionCurve(a,setting);delete a.sessions;input.sources[ds]={name:SRC[ds],...a,compactCurve:curve};}}
  finally{db.close();}
  return input;}

// ---- 3. rules: which items appear (mechanical cache loss only), with the numbers that justify them ----
const THRESH={coldShare:3,switchShare:0.5,switchMin:2,compactSave:3};
function rules(input){const F=[];
  const add=(id,source,impact,facts,fixed)=>F.push({id,source,impact,facts,shares:[facts.share],fixed});
  for(const [k,s] of Object.entries(input.sources)){const share=x=>pct1(x,s.total);
    if(s.cold.n>=3&&share(s.cold.burden)>=THRESH.coldShare){const life=s.lifetime;
      add('cold-'+k,s.name,s.cold.burden,{source:s.name,restarts:s.cold.n,burden:Math.round(s.cold.burden),share:share(s.cold.burden),cacheMinutes:life,readRatio:s.readRatio},
        {criterion:1,title:`${s.name}: 캐시가 살아 있을 때 이어 쓰기`,why:`오래 쉬다 돌아와 캐시가 만료된 뒤 대화 전체를 다시 저장한 게 ${s.cold.n}번, 한도 부담 ${fmt(s.cold.burden)}(${s.name} 전체의 ${share(s.cold.burden)}%)이에요.${life?` 기록상 캐시는 대략 ${life}분까지 살아 있었어요.`:''}`,
         how:life?`대략 ${life}분 안에 이어서 쓰면 캐시를 다시 읽는 것(새 입력의 ${s.readRatio}배)으로 끝나요. 오래 쉴 거면 정리해 두고 새 대화로 시작해요.`:`캐시가 살아 있을 때 이어서 써요. 오래 쉴 거면 정리해 두고 새 대화로 시작해요.`});}
    if(s.switch.n>=THRESH.switchMin&&share(s.switch.burden)>=THRESH.switchShare)
      add('switch-'+k,s.name,s.switch.burden,{source:s.name,switches:s.switch.n,burden:Math.round(s.switch.burden),share:share(s.switch.burden)},
        {criterion:2,title:`${s.name}: 모델은 대화 처음에 정하기`,why:`대화 중간에 모델을 바꿔 대화 전체를 다시 저장한 게 ${s.switch.n}번, 한도 부담 ${fmt(s.switch.burden)}(${s.name} 전체의 ${share(s.switch.burden)}%)이에요.`,how:'모델과 생각 단계는 대화를 시작할 때 정하고, 바꿀 일이 생기면 새 대화에서 바꿔 캐시를 이어 써요.'});
  }
  // compaction: Aside's one setting (all Aside sources together), Claude Code's own window
  for(const [group,keys,where] of [['Aside',[...ASIDE_SETS],'Aside 설정에서 자동 압축 기준을'],['Claude Code',['claude_cli_local'],'CLAUDE_CODE_AUTO_COMPACT_WINDOW를']]){
    const src=keys.map(k=>[k,input.sources[k]]).filter(([,s])=>s&&s.compactCurve);if(!src.length)continue;
    const p=pickCompaction(src.map(([,s])=>s.compactCurve));if(!p)continue;
    const c0=src[0][1].compactCurve,u=c0.unit==='%'?'%':' 토큰',cur=c0.unit==='%'?c0.current:fmt(c0.current),pick=c0.unit==='%'?p.pick:fmt(p.pick),lower=p.lower;
    const rows=src.map(([k,s],i)=>({name:s.name,n:s.compact.n,rb:s.compact.burden,rs:pct1(s.compact.burden,s.total),n2:p.per[i].n,save:p.per[i].save,ss:p.per[i].saveShare}));
    const facts={setting:group,current:c0.current,pick:p.pick,direction:lower?'lower':'higher'};
    rows.forEach((r,i)=>Object.assign(facts,{['source'+(i+1)]:r.name,['compactions'+(i+1)]:r.n,['newCompactions'+(i+1)]:r.n2,['rewriteBurden'+(i+1)]:Math.round(r.rb),['rewriteShare'+(i+1)]:r.rs,['save'+(i+1)]:Math.round(r.save),['saveShare'+(i+1)]:r.ss}));
    const f={criterion:3,title:`${group} 자동 압축 기준은 ${cur}${u}보다 ${pick}${u} 쪽이 부담이 적어요`,
      why:`압축 뒤 대화를 다시 저장한 부담은 ${rows.map(r=>`${r.name} ${r.n}번 ${fmt(r.rb)}(전체의 ${r.rs}%)`).join(', ')}로 작아요. 기록된 대화로 다시 계산하면 ${pick}${u}로 ${lower?'낮출':'올릴'} 때 압축은 ${rows.map(r=>`${r.name} ${r.n}→${r.n2}번`).join(', ')}으로 ${lower?'늘지만':'줄고'} ${lower?'요청마다 싣는 맥락이 작아져서':''} 부담이 ${rows.map(r=>`${r.name} ${fmt(r.save)}(전체의 ${r.ss}%)`).join(', ')} 적어져요. 요약 뒤 다시 찾아 읽는 양은 이 계산에 없어요.`.replace(/  +/g,' '),
      how:`${where} ${pick}${u}로 ${lower?'낮춰요':'올려요'}.${lower?' 압축하면 앞 내용은 요약돼요.':''}`};
    F.push({id:'compact-'+group,source:group,impact:Math.max(...rows.map(r=>r.save)),facts,shares:rows.flatMap(r=>[r.rs,r.ss]),fixed:f});}
  return F.sort((x,y)=>y.impact-x.impact);}

// neutral lines (not advice): burden per source, cache hit rate, model shares, compaction cost when no item, unsupported sources
function infoLines(input,findings){const out=[];
  const list=Object.entries(input.sources).sort((a,b)=>b[1].total-a[1].total);
  for(const [k,s] of list){const notes=[];if(s.ttlUnknown)notes.push('캐시 저장 시간이 기록에 없어 저장은 1.25배(5분 기준)로 계산했어요'+(s.lifetime>=30?`. 기록상 캐시가 ${s.lifetime}분 가까이 살아 있어 실제로는 1시간 저장(2배)일 수 있어요.`:'.'));if(s.outUnknown.length)notes.push(s.outUnknown.slice(0,4).join(', ')+'는 공개 출력 요금 비율을 확인하지 못해 4배로 계산했어요.');
    out.push({title:`${s.name}: 한도 부담 ${fmt(s.total)}, 캐시 적중 ${s.hitPct}%`,why:`모델별 한도 부담 비중: ${s.byModel.slice(0,4).map(m=>m.label+' '+(m.share<1?'1% 미만':m.share+'%')).join(', ')}. 캐시 다시 읽기는 새 입력의 ${s.readRatio}배라 적중률이 높을수록 좋아요.${notes.length?' '+notes.join(' '):''}`});
    if(s.compact.n>=3&&!findings.some(f=>f.id===(ASIDE_SETS.has(k)?'compact-Aside':'compact-Claude Code')))out.push({title:`${s.name}: 자동 압축 뒤 다시 저장 ${s.compact.n}번, 부담 ${fmt(s.compact.burden)}(전체의 ${pct1(s.compact.burden,s.total)}%)`,why:s.compactCurve?'기록된 대화로 다시 계산하면 압축 기준을 바꿔도 부담 차이가 작아서 지금 기준을 그대로 둬도 돼요.':'압축 기준 설정을 읽지 못해 방향은 계산하지 않았어요.'});}
  if(input.excluded.length)out.push({title:`${input.excluded.join(', ')}: 한도 부담 계산 지원 안 함`,why:'캐시 기록이 없거나 요금 기준이 확인되지 않아 부담 계산에서 뺐어요.'});
  return out.slice(0,8);}

// ---- 4. guardrails on model text ----
const BANNED=[
  {re:/(쉬|공백|만료|휴식)[^.。]{0,30}(\/compact|압축)/,unless:/말고|말아|마세요|않|대신 새|정리해/,why:'contradicts guidance: compacting after the cache expired is the most expensive case'},
  {re:/다시\s*읽[^.。]{0,25}(줄이|줄여|줄일|아끼|아껴|피하|피해|낮추|낮춰)/,why:'re-reads are cheap cache hits; never advise cutting them'},
  {re:/(캐시|재사용|적중)[^.。]{0,15}(줄이|줄여|아끼|아껴|낭비)/,why:'cache use is good; never advise using less of it'},
  {re:/(대화|작업)[^.。]{0,12}(나누|나눠|쪼개|분리)/,why:'splitting conversations because of re-reads is not advised'},
  {re:/(sonnet|haiku|opus|소넷|하이쿠|오퍼스|싼 모델|작은 모델|가벼운 모델)/i,why:'model choice is not waste; no model advice'},
  {re:/(원|달러|\$|USD|비용이\s*\d)/,why:'no money amounts'},
  {re:/[a-z]+[A-Z][A-Za-z]+|\b(burden|share|readRatio|cacheMinutes)\b/,why:'raw field names'}];
function numbersOf(text){const out=[];const re=/(\d[\d,]*(?:\.\d+)?)\s*(억|만|%|배|분|줄|개|번)?/g;let m;while((m=re.exec(text))){let v=Number(m[1].replace(/,/g,''));if(m[2]==='억')v*=1e8;else if(m[2]==='만')v*=1e4;out.push(v);}return out;}
const CONST_NUMS=[0.1,0.25,1,1.25,2,4,5,8,30];
function validate(items,findings){const byId=new Map(findings.map(f=>[f.id,f]));const kept=[],dropped=[];
  for(const it of Array.isArray(items)?items:[]){const f=it&&byId.get(String(it.id||''));const text=[it&&it.title,it&&it.why,it&&it.how].map(x=>typeof x==='string'?x:'').join(' ');
    let reason=null;if(!it||!it.title||!it.why||!it.how)reason='missing fields';else if(!f)reason='item not among the findings';else if(text.length>600)reason='too long';
    else{const nums=new Set(CONST_NUMS);for(const v of Object.values(f.facts))if(typeof v==='number')nums.add(v);for(const v of numbersOf([f.fixed.title,f.fixed.why,f.fixed.how].join(' ')))nums.add(v);
      const ok=n=>{if(nums.has(n))return true;for(const v of nums)if(v>=1e4&&Math.abs(v-n)/v<0.06)return true;return false;};
      const bad=numbersOf(text).filter(n=>!ok(n));
      if(bad.length)reason='numbers not in findings: '+bad.slice(0,3).join(', ');
      else{const sentences=text.split(/[.。!?\n]/);const b=BANNED.find(x=>sentences.some(s=>x.re.test(s)&&!(x.unless&&x.unless.test(s))));if(b)reason=b.why;
        else if(f.facts.direction==='lower'&&/(높여|높이|올려|올리)/.test(text))reason='direction contradicts the replay';
        else if(f.facts.direction==='higher'&&/(낮춰|낮추)/.test(text))reason='direction contradicts the replay';
        else if(!numbersOf(text).some(n=>(f.shares||[]).includes(n)))reason='share of total missing';}}
    if(reason)dropped.push({title:String(it&&it.title||'').slice(0,80),reason});else kept.push({id:f.id,criterion:[f.fixed.criterion],title:it.title.trim(),why:it.why.trim(),how:it.how.trim()});}
  return {kept:kept.slice(0,5),dropped};}

// ---- 5. the model call ----
function prompt(findings){return `아래는 한 사람의 AI 토큰 사용 기록을 코드로 점검해 이미 판정한 결과예요(대화 내용 없음, 집계값만).
판정 원칙(반드시 지켜요):
- 캐시 다시 읽기는 좋은 거예요. 새 입력의 약 0.1배 부담이라, 다시 읽은 양이 많거나 몇 배라는 이유로 줄이라고 하지 말아요. 대화를 나누라고 하지 말아요.
- 부담은 "한도 부담(요금 기준 추정)"이에요: 새 입력×1 + 캐시 저장×1.25(5분)·2(1시간) + 캐시 다시 읽기×0.1 + 출력×모델 비율. ${PRICE_NOTE}.
- 낭비로 보는 건 캐시를 잃은 경우뿐이에요: 오래 쉬어 캐시가 만료된 뒤 다시 저장, 대화 중간 모델 전환, 자동 압축 뒤 다시 저장.
- 어떤 모델을 쓰는지는 낭비가 아니에요. 모델 이름(Opus, Sonnet, Haiku 등)을 꺼내거나 더 작은 모델로 바꾸라고 하지 말아요.
- 압축 기준은 facts의 direction 방향으로만 말해요(lower=낮추기, higher=올리기).
규칙:
- 아래 항목만 다뤄요. 항목을 더하거나 빼지 말고, id를 그대로 써요.
- 숫자는 facts와 draft에 있는 값만 쓰고 새로 계산하지 말아요. 각 항목에 부담 숫자와 전체 대비 비율(%)을 꼭 넣어요.
- 비용이나 돈은 말하지 말아요. 서로 다른 출처(source)의 숫자를 더하지 말아요.
- 쉬었다 돌아온 뒤 압축하라고 하지 말아요(그때가 가장 비싸요).
할 일: draft를 더 쉽고 긍정적인 한국어로 다듬어요. 캐시를 살려 쓰는 쪽으로, 짧게, 존댓말("~해요").
출력: JSON 배열만. [{"id":"...","title":"...","why":"...","how":"..."}]

항목(코드 판정, 부담 큰 순):
${JSON.stringify(findings.map(f=>({id:f.id,facts:f.facts,draft:{title:f.fixed.title,why:f.fixed.why,how:f.fixed.how}})),null,1)}`;}
// macOS: launchd and the menu bar app start with a minimal PATH, so also look where Homebrew and the official installers put the CLIs
const EXTRA_DIRS=process.platform==='darwin'?[path.join(os.homedir(),'.local','bin'),'/opt/homebrew/bin','/usr/local/bin']:[];
function which(names){for(const n of names){for(const dir of [...(process.env.PATH||'').split(path.delimiter),...EXTRA_DIRS]){const p=path.join(dir,n);if(dir&&fs.existsSync(p))return p;}}return null;}
function runCli(exe,args,input,cwd,timeoutMs){return new Promise(res=>{let out='',err='',done=false;const shell=/\.(cmd|bat)$/i.test(exe);
  const p=spawn(exe,args,{cwd,windowsHide:true,shell});const t=setTimeout(()=>{if(!done){done=true;try{p.kill();}catch{}res({ok:false,reason:'timeout'});}},timeoutMs);
  p.stdout.on('data',d=>{out+=d;if(out.length>200000)p.kill();});p.stderr.on('data',d=>{err+=d;if(err.length>200000)err=err.slice(-100000);});
  p.on('error',e=>{if(!done){done=true;clearTimeout(t);res({ok:false,reason:'spawn_failed'});}});
  p.on('close',code=>{if(done)return;done=true;clearTimeout(t);res({ok:code===0,out,reason:code===0?null:'exit_'+code});});
  p.stdin.end(input);});}
function parseArray(text){const a=String(text||'').indexOf('['),b=String(text||'').lastIndexOf(']');if(a<0||b<a)return null;try{const v=JSON.parse(text.slice(a,b+1));return Array.isArray(v)?v:null;}catch{return null;}}
async function askModel(findings,{workDir,home=os.homedir(),timeoutMs=150000}={}){
  fs.mkdirSync(workDir,{recursive:true});const p=prompt(findings);
  const mac=process.platform==='darwin';
  const claude=(mac?[path.join(home,'.local','bin','claude'),which(['claude'])]:[path.join(home,'.local','bin','claude.exe'),which(['claude.exe','claude.cmd'])]).find(x=>x&&fs.existsSync(x));
  if(claude){const r=await runCli(claude,['-p','--model','haiku','--output-format','text','--disallowedTools','Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Task,NotebookEdit'],p,workDir,timeoutMs);const arr=r.ok?parseArray(r.out):null;if(arr)return {model:'Claude Haiku',items:arr};}
  const codex=which(mac?['codex']:['codex.cmd','codex.exe']);
  if(codex){const r=await runCli(codex,['exec','--model','gpt-6-luna','--skip-git-repo-check','--sandbox','read-only','-'],p,workDir,timeoutMs);const arr=r.ok?parseArray(r.out):null;if(arr)return {model:'GPT-6 Luna',items:arr};}
  return {model:null,items:[]};}

// ---- 6. whole check: model text where it passes, fixed text for anything it dropped or missed; order = 부담 ----
async function habitCheck({snap,names,indexPath,workDir,home,useModel=true,now=Date.now(),ask=askModel}){
  const input=buildInput({snap,names,indexPath,home,now}),findings=rules(input),info=infoLines(input,findings);
  const base={at:new Date(now).toISOString(),basis:BASIS,info,rules:'cache-v1'};
  if(!findings.length)return {...base,model:null,items:[],dropped:[],findings:0};
  const ans=useModel?await ask(findings,{workDir,home}):{model:null,items:[]};
  const {kept,dropped}=validate(ans.items,findings);
  const seen=new Set(),items=[];for(const k of kept)if(!seen.has(k.id)){seen.add(k.id);items.push({...k,by:'model'});}
  for(const f of findings)if(!seen.has(f.id)){seen.add(f.id);items.push({id:f.id,...f.fixed,criterion:[f.fixed.criterion],by:'rule'});}
  const rank=new Map(findings.map((f,i)=>[f.id,i]));items.sort((a,b)=>rank.get(a.id)-rank.get(b.id));
  return {...base,model:items.some(i=>i.by==='model')?ans.model:null,items:items.slice(0,5),dropped,findings:findings.length};}

module.exports={buildInput,analyze,replay,compactionCurve,pickCompaction,rules,infoLines,validate,habitCheck,prompt,BANNED,PRICES,PRICE_NOTE,BASIS,numbersOf,priceFor};
