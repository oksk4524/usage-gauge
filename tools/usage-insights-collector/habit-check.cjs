'use strict';
// "AI habit check" (cache-aware rules, 2026-10-30). Code decides everything: which items appear, their order and every
// number. A small model (Haiku, else Luna) only rewords the fixed texts; each sentence is checked and anything that
// fails falls back to the fixed text. Sends aggregates only (token counts, source names, settings numbers); never
// conversation content, titles or project names.
//
// Principles (approved by the owner):
//  a) Cache re-reads are good: they cost about 0.1x new input. The cache hit rate (re-read share of input) is shown as
//     a positive number. A high re-read multiple is never a reason to cut re-reads or to split conversations.
//  b) Items are ranked by "한도를 쓴 양(요금 기준 추정)" = each model's absolute public prices (PRICE_TABLE): new input x in
//     + cache write x in x (Claude 1.25 five-minute, 2 one-hour, 1.25 and a note when the lifetime is not recorded;
//     OpenAI and xAI 1) + cache read x cached price + output x output price. One unit for every model, shown only as
//     shares and percentages; models without a listed price are "가격 미상" and left out of the shares.
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
// on screen percentages are whole numbers (WRITING.md 3); under 1% reads "1% 미만"
const P=x=>x<1?'1% 미만':Math.round(x)+'%',PN=x=>x<1?1:Math.round(x);
const fmt=n=>{n=Math.round(n);return n>=1e8?(Math.round(n/1e7)/10)+'억':n>=1e4?Math.round(n/1e4)+'만':String(n);};

// ---- price table: public API list prices, USD per 1M tokens, standard tier, short prompts (checked 2026-10-31) ----
// Every model is weighted by its own absolute prices, so models and sources share one unit and their shares are
// comparable. The page shows shares and percentages only, never money. Units per request:
//   new input x in + cache write x in x (Claude 1.25 five-minute, 2 one-hour; OpenAI and xAI 1) + cache read x read + output x out
// Sources (checked 2026-10-31): Claude platform.claude.com/docs/en/models (Opus 5.5, Sonnet 5.5 and Haiku 5.5 pages,
// list price PDF effective 2026-10-22); OpenAI developers.openai.com/api/docs/models/<id>, the GPT-6.1 Sol and GPT-5.6
// price announcements; xAI docs.x.ai/developers/models/grok-4.7 (Grok 4.6 is served at the same price).
// Not applied: long-prompt surcharges (OpenAI over 272K input, xAI over 200K, Haiku 5.5 over 100K), batch, fast mode, and
// the end of GPT-5.6 Sol's promotion. OpenAI lists a cache-write rate, but its logs report a miss as input and cacheCreate
// stays 0, so writes count at 1x input there (as the owner's rule says). A model not in this table is "가격 미상": its
// tokens are still listed, but it is left out of every share. Subscription limits are not published, so this stays an estimate.
const PRICE_NOTE='공개 API 요금 비율 기준, 구독 한도 실제 차감 방식은 비공개라 추정';
const PRICE_CHECKED='2026-10-31';
const PRICE_TABLE=[
  // id pattern, family, input, cached input (cache read), output: USD per 1M tokens
  {re:/^claude-opus-5-5/i,label:'Claude Opus 5.5',family:'claude',in:4,read:0.2,out:20},
  {re:/^claude-sonnet-5-5/i,label:'Claude Sonnet 5.5',family:'claude',in:2,read:0.1,out:10},
  {re:/^claude-haiku-5-5/i,label:'Claude Haiku 5.5',family:'claude',in:0.1,read:0.01,out:0.5},
  {re:/^gpt-6-astra/i,label:'GPT-6 Astra',family:'openai',in:10,read:1,out:50},
  {re:/^gpt-6\.1-sol/i,label:'GPT-6.1 Sol',family:'openai',in:2,read:0.1,out:10},
  {re:/^gpt-6\.1-terra/i,label:'GPT-6.1 Terra',family:'openai',in:1,read:0.05,out:5},
  {re:/^gpt-6-sol/i,label:'GPT-6 Sol',family:'openai',in:2,read:0.2,out:10},
  {re:/^gpt-6-luna/i,label:'GPT-6 Luna',family:'openai',in:0.1,read:0.01,out:0.5},
  {re:/^gpt-5\.6-sol/i,label:'GPT-5.6 Sol',family:'openai',in:4,read:0.4,out:20},
  {re:/^gpt-5\.6-terra/i,label:'GPT-5.6 Terra',family:'openai',in:2,read:0.2,out:12},
  {re:/^gpt-5\.6-luna/i,label:'GPT-5.6 Luna',family:'openai',in:0.2,read:0.02,out:1.2},
  {re:/^grok-4\.7/i,label:'Grok 4.7',family:'xai',in:2,read:0.5,out:6},
  {re:/^grok-4\.6/i,label:'Grok 4.6',family:'xai',in:2,read:0.5,out:6}];
const CLAUDE_WRITE={m5:1.25,h1:2},UNKNOWN_TTL_WRITE=CLAUDE_WRITE.m5,M1=1e6;
const PRICES=PRICE_TABLE;   // the old export name
// absolute prices per token; known:false = 가격 미상 (every price 0, so the model adds nothing to any share)
function priceFor(dataset,model){const m=String(model||''),p=PRICE_TABLE.find(x=>x.re.test(m)),claude=/^claude/.test(dataset);
  if(!p)return {family:claude?'claude':'?',in:0,read:0,out:0,write:claude?null:0,write5m:0,write1h:0,known:false};
  const in1=p.in/M1;
  return p.family==='claude'?{family:p.family,in:in1,read:p.read/M1,out:p.out/M1,write5m:in1*CLAUDE_WRITE.m5,write1h:in1*CLAUDE_WRITE.h1,known:true}
    :{family:p.family,in:in1,read:p.read/M1,out:p.out/M1,write:in1,known:true};}
function modelLabel(id){const s=String(id||'');if(!s||s==='unknown')return '모델 기록 없음';
  let m=s.match(/^claude-([a-z]+)-(\d+)-(\d+)/i);if(m)return m[1][0].toUpperCase()+m[1].slice(1)+' '+m[2]+'.'+m[3];
  m=s.match(/^gpt-([\d.]+)-?(.*)$/i);if(m)return 'GPT-'+m[1]+(m[2]?' '+m[2].split('-').map(w=>w&&w[0].toUpperCase()+w.slice(1)).join(' '):'');
  m=s.match(/^(grok|gemini)-(.+)$/i);if(m)return m[1][0].toUpperCase()+m[1].slice(1)+' '+m[2];return s.slice(0,40);}
// on-screen wording (owner, 2026-10-30): "한도를 쓴 양", never "부담", "비중" or "가중"; the weights stay in PRICES above
const BASIS='캐시 적중은 높을수록 좋아요. 한도를 쓴 양은 모델마다 공개 API 요금으로 새 입력, 다시 읽기(캐시), 새로 저장(캐시), AI가 쓴 답을 쳐서 비율로만 보여 주는 요금 기준 추정이에요. 표는 모든 출처를 더한 것 중 몫이고, 지난 30일 기록이에요.';
// house writing rules (WRITING.md at the repository root, copied next to the code by the installers); the model follows them every time
function writingRules(){for(const p of [path.resolve(__dirname,'..','..','WRITING.md')]){try{const t=fs.readFileSync(p,'utf8').replace(/^#.*\n+/,'').trim();if(t)return t;}catch{}}return '해요체로 짧게 써요. 가운데 점은 쓰지 말고 나열은 쉼표로 써요. "한도를 쓴 양"이라고 쓰고 "부담", "비중", "가중"은 쓰지 않아요.';}

// ---- 1. measure one dataset from its request records (sorted by session, then time) ----
const EV={minPrev:20000,idleMin:5,compactPrev:100000};
// Cache lifetime from the records (audit, 2026-10-30): for consecutive requests in the same conversation and model, with
// a previous context of at least 2만 tokens, the next request is a hit when it re-reads at least half of the previous
// context from cache and a miss when it re-reads less than half and writes at least half again (a shrink, which is a
// compaction, is neither). Hit rate per idle-gap bucket; the lifetime is the start of the first bucket (5 minutes and
// up, at least LIFE.minEval samples) where the hit rate falls below 50%. It counts as "기록으로 확인함" only when that
// bucket and the last bucket before it that still had 50% or more each hold at least LIFE.confirmN samples.
const GAP_BUCKETS=[[0,5],[5,10],[10,20],[20,30],[30,45],[45,60],[60,90],[90,Infinity]];
const LIFE={minEval:5,confirmN:20,hit:50};
function gapTable(hits,misses){return GAP_BUCKETS.map(([from,to])=>{const h=hits.filter(g=>g>=from&&g<to).length,m=misses.filter(g=>g>=from&&g<to).length;return {from,to:to===Infinity?null:to,n:h+m,hits:h,hitPct:h+m?Math.round(100*h/(h+m)):null};});}
function lifetimeOf(table){let last=null;for(const b of table){if(b.from<5||b.n<LIFE.minEval)continue;if(b.hitPct<LIFE.hit)return {minutes:b.from,confirmed:b.n>=LIFE.confirmN&&!!last&&last.n>=LIFE.confirmN,below:b,above:last};last=b;}return null;}
const EVIDENCE={recorded:'기록으로 확인함',estimate:'추정'};
function writeBurden(r,p,unknownWrite){const cw=r.cacheCreate||0;if(p.write!=null)return {b:cw*p.write,unknown:0};const k1=Math.min(cw,r.cw1h||0),k5=Math.min(cw-k1,r.cw5m||0),rest=cw-k1-k5;return {b:k5*p.write5m+k1*p.write1h+rest*p.in*unknownWrite,unknown:rest,k1,k5};}
function measure(dataset,rows,unknownWrite){
  const ctx=r=>(r.input||0)+(r.cacheRead||0)+(r.cacheCreate||0);
  const t={total:0,input:0,write:0,read:0,output:0,outTok:0,inTok:0,readTok:0,writeTok:0,unknownTtl:0,w1h:0,w5m:0,kCtx:0,kInCost:0,kRead:0,kWrite:0,kOut:0},models=new Map(),unpriced=new Map();
  const misses=[],sw={n:0,tokens:0,burden:0},comp={n:0,tokens:0,burden:0,pre:[],post:[],cost:[]},hitGaps=[],missGaps=[];
  const sess=[];let cur=null,prev=null;
  for(const r of rows){const p=priceFor(dataset,r.model),w=writeBurden(r,p,unknownWrite),b=(r.input||0)*p.in+w.b+(r.cacheRead||0)*p.read+(r.output||0)*p.out;r._b=b;r._p=p;r._w=w.b;r._kind=null;
    t.total+=b;t.input+=(r.input||0)*p.in;t.write+=w.b;t.read+=(r.cacheRead||0)*p.read;t.output+=(r.output||0)*p.out;t.outTok+=r.output||0;t.inTok+=r.input||0;t.readTok+=r.cacheRead||0;t.writeTok+=r.cacheCreate||0;t.unknownTtl+=w.unknown;t.w1h+=w.k1||0;t.w5m+=w.k5||0;
    // 가격 미상: tokens are kept for the list, nothing goes into a share
    const ml=modelLabel(r.model),tok=ctx(r)+(r.output||0);
    if(p.known){models.set(ml,(models.get(ml)||0)+b);t.kCtx+=ctx(r);t.kInCost+=ctx(r)*p.in;t.kRead+=r.cacheRead||0;t.kWrite+=r.cacheCreate||0;t.kOut+=r.output||0;}
    else if(tok>0)unpriced.set(ml,(unpriced.get(ml)||0)+tok);
    if(!cur||cur.id!==r.session){cur={id:r.session,rows:[]};sess.push(cur);prev=null;}cur.rows.push(r);
    if(prev&&r.session&&r.session!=='unknown'){const pc=ctx(prev),c=ctx(r),gap=(r.at-prev.at)/60000,same=!(r.model&&prev.model&&r.model!=='unknown'&&prev.model!=='unknown'&&r.model!==prev.model),rew=(r.input||0)+(r.cacheCreate||0),rb=(r.input||0)*p.in+r._w;
      if(pc>=EV.minPrev){
        if((r.cacheRead||0)>=pc*0.5){if(same)hitGaps.push(gap);}
        else if(rew>=pc*0.5){if(!same){sw.n++;sw.tokens+=rew;sw.burden+=rb;r._kind='switch';}else{missGaps.push(gap);misses.push({gap,tokens:rew,burden:rb,prevCtx:pc,r});}}
        else if(same&&c<pc*0.5&&pc>=EV.compactPrev){comp.n++;comp.tokens+=rew;comp.burden+=rb;comp.pre.push(pc);comp.post.push(c);comp.cost.push(rb);r._kind='compact';}}}
    prev=r;}
  return {t,models,unpriced,misses,sw,comp,hitGaps,missGaps,sess};}
function coldSaving(x){const paid=x.burden,tok=x.tokens;if(!(paid>0)||!(tok>0))return 0;
  const reusable=Math.max(0,Math.min(tok,(x.prevCtx||0)-(x.r.cacheRead||0))),rate=paid/tok,read=x.r._p.read||0;
  return reusable*Math.max(0,rate-read);}
function analyze(dataset,rows){
  const claude=/^claude/.test(dataset);let m=measure(dataset,rows,UNKNOWN_TTL_WRITE),ttlAssumed=null;
  const med=a=>{if(!a.length)return null;const s=[...a].sort((x,y)=>x-y);return s[Math.floor(s.length/2)];};
  const table=gapTable(m.hitGaps,m.missGaps);
  // lifetime: recorded (1-hour / 5-minute writes) first, else measured from the gap buckets
  let lifetime=null,lifeFrom=null,lifeConfirmed=false,life=null;
  if(m.t.w1h>m.t.writeTok*0.5){lifetime=60;lifeFrom='recorded';lifeConfirmed=true;}else if(m.t.w5m>m.t.writeTok*0.5){lifetime=5;lifeFrom='recorded';lifeConfirmed=true;}
  else{life=lifetimeOf(table);if(life){lifetime=life.minutes;lifeFrom='measured';lifeConfirmed=life.confirmed;}}
  // Claude writes with no recorded lifetime: a cache that clearly outlives 5 minutes (gaps of 10 to 30 minutes, at least
  // 20 samples, half or more still hits) is a 1-hour cache, so those writes count 2x instead of 1.25x (요금 기준 추정)
  const mid=table.filter(b=>b.from>=10&&b.from<30),midN=mid.reduce((n,b)=>n+b.n,0),midH=mid.reduce((n,b)=>n+b.hits,0);
  if(claude&&lifeFrom!=='recorded'&&m.t.unknownTtl>m.t.writeTok*0.5&&midN>=LIFE.confirmN&&midH*2>=midN){m=measure(dataset,rows,2);ttlAssumed='1h';}
  const t=m.t;
  // cold restarts: misses after an idle gap at or past the lifetime (or 5 minutes when it is unknown); coming back sooner
  // turns these into re-reads. Misses inside the lifetime have another cause and are counted apart, never as advice.
  // burden = what the miss paid for its input side (new input plus cache write). save = what a living cache would have
  // spared: the part of the previous context not already read this time (capped by that context and by what was paid
  // for) costs a cache read instead; the new input is paid either way at the same rate.
  const floor=lifetime!=null?Math.max(EV.idleMin,lifetime):EV.idleMin,cold={n:0,tokens:0,burden:0,save:0,gaps:[]},inside={n:0,tokens:0,burden:0};
  for(const x of m.misses){if(x.gap>=floor){cold.n++;cold.tokens+=x.tokens;cold.burden+=x.burden;cold.save+=coldSaving(x);cold.gaps.push(x.gap);x.r._kind='cold';}else if(x.gap>=EV.idleMin){inside.n++;inside.tokens+=x.tokens;inside.burden+=x.burden;}}
  const pool=(lo,hi)=>{const bs=table.filter(b=>b.from>=lo&&(hi==null||b.from<hi)),n=bs.reduce((s,b)=>s+b.n,0),h=bs.reduce((s,b)=>s+b.hits,0);return {n,hitPct:n?Math.round(100*h/n):null};};
  const byModel=[...m.models].filter(([,b])=>b>0).sort((a,b)=>b[1]-a[1]).map(([label,b])=>({label,share:pct(b,t.total)}));
  // writeRatio: the cache-write multiple of input (the dashboard reads it for Claude); price: the source's average
  // absolute prices per token over its priced models, for the compaction replay (same unit as total)
  const writeRatio=claude?(ttlAssumed==='1h'?CLAUDE_WRITE.h1:UNKNOWN_TTL_WRITE):1;
  const pin=t.kCtx?t.kInCost/t.kCtx:0,price={in:pin,read:t.kRead?t.read/t.kRead:pin*0.1,write:t.kWrite?t.write/t.kWrite:pin*writeRatio,out:t.kOut?t.output/t.kOut:pin*5};
  const unpriced=[...m.unpriced].sort((a,b)=>b[1]-a[1]).map(([label,tokens])=>({label,tokens}));
  return {total:t.total,parts:{input:t.input,write:t.write,read:t.read,output:t.output},hitPct:pct(t.readTok,t.readTok+t.inTok+t.writeTok),price,readRatio:pin?price.read/pin:0.1,writeRatio,outRatio:pin?price.out/pin:5,
    ttlUnknown:t.writeTok>0&&t.unknownTtl>t.writeTok*0.5&&claude,ttlAssumed,unpriced,byModel,lifetime,lifeFrom,lifeConfirmed,gapTable:table,
    hitBefore:lifetime!=null?pool(EV.idleMin,lifetime):null,hitAfter:lifetime!=null?pool(lifetime,null):null,
    cold:{n:cold.n,tokens:cold.tokens,burden:cold.burden,save:cold.save,medianGap:cold.gaps.length?Math.round(med(cold.gaps)):null},coldInside:inside,switch:m.sw,
    compact:{n:m.comp.n,tokens:m.comp.tokens,burden:m.comp.burden,pre:med(m.comp.pre),post:med(m.comp.post),cost:med(m.comp.cost)},sessions:m.sess};}

// Replays the recorded conversations with a different compaction point: context grows by the recorded steps, a
// compaction drops it to the measured post-compaction size and costs the measured rewrite plus the summary call, which
// is not in the records: it reads the whole conversation (from cache, or at 1x when `summaryIn` is 'full') and writes
// a summary of SUMMARY_OUT tokens at the output ratio. `reread` = tokens the agent reads again after each summary
// (unknown, not in the records): written to cache once and carried in the context afterwards. Every other request reads
// its context from cache.
// Summary size: median of the 226 compaction summaries in this Mac's Aside conversations (2026-10-30), 7,597 characters,
// about 3,400 tokens (Korean syllable 1 token, other characters 3.5 per token). An estimate, the summaries carry no token count.
const SUMMARY_OUT=3400,REREAD_TEST=50000;
function replay(a,T,{summaryIn='read',reread=0,summaryOut=SUMMARY_OUT}={}){let total=0,n=0;const pr=a.price,B=a.compact.post,C=a.compact.cost,read=pr.read,inR=summaryIn==='full'?pr.in:read,out=pr.out,wr=pr.write;
  const fire=c=>{n++;total+=C+inR*c+out*summaryOut+wr*reread;return B+reread;};
  for(const s of a.sessions){const ctx=r=>(r.input||0)+(r.cacheRead||0)+(r.cacheCreate||0);let c=ctx(s.rows[0]);if(c>T)c=fire(c);total+=read*c;
    for(let i=1;i<s.rows.length;i++){const r=s.rows[i],d=r._kind?0:Math.max(0,ctx(r)-ctx(s.rows[i-1]));c+=d;if(c>T)c=fire(c);total+=read*c;}}
  return {total,n};}
// The replay does not see the extra reading an agent does after each summary, so candidates stop at half the window.
const COMPACT_CANDIDATES=[50,60,70,80,90,95];
function compactionCurve(a,setting){if(!setting||a.compact.n<3||!a.compact.pre||!a.compact.post||a.compact.post>=a.compact.pre)return null;
  const T=a.compact.pre,base=replay(a,T),cand=[],full={summaryIn:'full'},rr={reread:REREAD_TEST},baseFull=replay(a,T,full),baseRr=replay(a,T,rr);
  if(setting.percent){for(const q of COMPACT_CANDIDATES)if(q!==setting.percent)cand.push({label:q,T:T*q/setting.percent});}
  else for(const f of [0.6,0.7,0.8,0.9,1.1])cand.push({label:Math.round(T*f/1e4)*1e4,T:T*f});
  const results=cand.filter(c=>c.T>a.compact.post*1.5).map(c=>{const r=replay(a,c.T),save=base.total-r.total,sf=baseFull.total-replay(a,c.T,full).total,sr=baseRr.total-replay(a,c.T,rr).total;
    return {label:c.label,lower:c.T<T,n:r.n,save,saveShare:pct1(save,a.total),saveFullShare:pct1(sf,a.total),saveRereadShare:pct1(sr,a.total)};});
  return results.length?{current:setting.percent||Math.round(T/1e4)*1e4,unit:setting.percent?'%':'tokens',replayCompactions:base.n,summaryOut:SUMMARY_OUT,rereadTest:REREAD_TEST,results}:null;}
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
// Advice only when the saving is large and survives the unknowns: at least 10% of every source's total with the summary
// call counted, also when that call reads at 1x, and also when the agent reads REREAD_TEST tokens again after each summary.
// Otherwise it is only "실험해 볼 거리" in the reference notes, never a settings instruction.
function compactionSolid(p){return p.per.every(r=>r.saveShare>=THRESH.compactAdvice&&r.saveFullShare>=THRESH.compactAdvice&&r.saveRereadShare>=THRESH.compactAdvice);}

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
    for(const [ds,rows] of by){const a=analyze(ds,rows);if(!(a.total>0)&&!a.unpriced.length)continue;
      const st=input.settings,setting=ASIDE_SETS.has(ds)?(st.aside&&st.aside.enabled&&st.aside.thresholdPercent>0?{percent:Math.round(st.aside.thresholdPercent)}:null):ds==='claude_cli_local'&&st.claudeCompactWindow?{tokens:st.claudeCompactWindow}:null;
      const curve=compactionCurve(a,setting);delete a.sessions;input.sources[ds]={name:SRC[ds],...a,compactCurve:curve};}}
  finally{db.close();}
  return input;}

// ---- 3. rules: which items appear (mechanical cache loss only), with the numbers that justify them ----
const THRESH={coldShare:3,switchShare:0.5,switchMin:2,compactSave:3,compactAdvice:10};
const eun=name=>{const c=String(name).slice(-1).charCodeAt(0);return c>=0xac00&&c<=0xd7a3?((c-0xac00)%28?'은':'는'):'는';};
function rules(input){const F=[];
  const add=(id,source,impact,facts,fixed,evidence)=>F.push({id,source,impact,facts,shares:[PN(facts.shareRaw)],fixed,evidence});
  for(const [k,s] of Object.entries(input.sources)){const share=x=>pct1(x,s.total);
    // the share is the saving (what a living cache would have spared), not what the misses paid; both are shares only
    const save=s.cold.save||0;
    if(s.cold.n>=3&&share(save)>=THRESH.coldShare){const life=s.lifetime,hb=s.hitBefore&&s.hitBefore.hitPct,ha=s.hitAfter&&s.hitAfter.hitPct,sh=P(share(save)),ms=P(share(s.cold.burden));
      const ev=life!=null&&(s.lifeFrom==='recorded'||s.lifeConfirmed)?EVIDENCE.recorded:EVIDENCE.estimate;
      const paid=`이때 한도를 쓴 양은 ${s.name} 전체의 ${ms}예요. 캐시가 남아 있었다면 앞 대화는 다시 읽기(캐시)로 끝나고 새로 넣은 내용만 그대로 들어요. 쉬는 걸 다 피할 수는 없어서 ${sh}는 최대치예요.`;
      add('cold-'+k,s.name,save,{source:s.name,restarts:s.cold.n,shareRaw:share(save),share:PN(share(save)),missShare:PN(share(s.cold.burden)),cacheMinutes:life,hitBefore:hb,hitAfter:ha},
        life?{criterion:1,title:`${s.name}${eun(s.name)} ${life}분 안에 이어 쓰면 한도를 최대 ${sh} 아껴요`,
          why:`${life}분 넘게 쉬었다 이어 써서 대화 전체를 새로 저장(캐시)한 게 ${s.cold.n}번이고, ${paid}${hb!=null&&ha!=null?` 기록상 ${life}분 안에 이어 쓰면 ${hb}%가 다시 읽기(캐시)였고, 넘기면 ${ha}%였어요.`:''}`,
          how:`${life}분 안에 이어서 쓰면 다시 읽기(캐시)로 끝나요. 오래 쉴 거면 정리해 두고 새 대화로 시작해요.`}
        :{criterion:1,title:`${s.name}${eun(s.name)} 캐시가 살아 있을 때 이어 쓰면 한도를 최대 ${sh} 아껴요`,
          why:`오래 쉬다 돌아와 대화 전체를 새로 저장(캐시)한 게 ${s.cold.n}번이고, ${paid}`,
          how:'캐시가 살아 있을 때 이어서 써요. 오래 쉴 거면 정리해 두고 새 대화로 시작해요.'},ev);}
    if(s.switch.n>=THRESH.switchMin&&share(s.switch.burden)>=THRESH.switchShare)
      add('switch-'+k,s.name,s.switch.burden,{source:s.name,switches:s.switch.n,shareRaw:share(s.switch.burden),share:PN(share(s.switch.burden))},
        {criterion:2,title:`${s.name}: 모델은 대화 처음에 정하기`,why:`대화 중간에 모델을 바꿔 대화 전체를 새로 저장(캐시)한 게 ${s.switch.n}번이에요. 이때 한도를 쓴 양은 ${s.name} 전체의 ${P(share(s.switch.burden))}예요.`,how:'모델과 생각 단계는 대화를 시작할 때 정하고, 바꿀 일이 생기면 새 대화에서 바꿔 캐시를 이어 써요.'},EVIDENCE.recorded);
  }
  // compaction: Aside's one setting (all Aside sources together), Claude Code's own window. Advice only when compactionSolid.
  for(const [group,keys,where] of COMPACT_GROUPS){
    const src=keys.map(k=>[k,input.sources[k]]).filter(([,s])=>s&&s.compactCurve);if(!src.length)continue;
    const p=pickCompaction(src.map(([,s])=>s.compactCurve));if(!p||!compactionSolid(p))continue;
    const c0=src[0][1].compactCurve,u=c0.unit==='%'?'%':' 토큰',cur=c0.unit==='%'?c0.current:fmt(c0.current),pick=c0.unit==='%'?p.pick:fmt(p.pick),lower=p.lower;
    const rows=src.map(([k,s],i)=>({name:s.name,n:s.compact.n,rb:s.compact.burden,rs:pct1(s.compact.burden,s.total),n2:p.per[i].n,save:p.per[i].save,ss:p.per[i].saveShare}));
    const facts={setting:group,current:c0.current,pick:p.pick,direction:lower?'lower':'higher',summaryOut:SUMMARY_OUT,rereadTest:REREAD_TEST};
    rows.forEach((r,i)=>Object.assign(facts,{['source'+(i+1)]:r.name,['compactions'+(i+1)]:r.n,['newCompactions'+(i+1)]:r.n2,['rewriteShare'+(i+1)]:PN(r.rs),['saveShare'+(i+1)]:PN(r.ss)}));
    const f={criterion:3,title:`${group} 자동 압축 기준은 ${cur}${u}보다 ${pick}${u} 쪽이 한도를 덜 써요`,
      why:`기록된 대화로 다시 계산하면 ${pick}${u}에서 압축은 ${rows.map(r=>`${r.name} ${r.n}→${r.n2}번`).join(', ')}으로 바뀌고 한도를 ${rows.map(r=>`${r.name} 전체의 ${P(r.ss)}`).join(', ')}만큼 덜 써요. 요약을 만드는 비용을 넣고, 요약 뒤 5만 토큰씩 다시 읽어도 같은 쪽이에요.`,
      how:`${where} ${pick}${u}로 ${lower?'낮춰요':'올려요'}.${lower?' 압축하면 앞 내용은 요약돼요.':''}`};
    F.push({id:'compact-'+group,source:group,impact:Math.max(...rows.map(r=>r.save)),facts,shares:rows.map(r=>PN(r.ss)),fixed:f,evidence:EVIDENCE.estimate});}
  return F.sort((x,y)=>y.impact-x.impact);}
const COMPACT_GROUPS=[['Aside',[...ASIDE_SETS],'Aside 설정에서 자동 압축 기준을'],['Claude Code',['claude_cli_local'],'CLAUDE_CODE_AUTO_COMPACT_WINDOW를']];

// Reference (not advice): one table row per source (한도를 쓴 양, 캐시 적중, 모델별로 한도를 쓴 양) and short notes said once:
// models without a listed price, assumed cache lifetime, the compaction "실험해 볼 거리", unsupported sources. BASIS is the one shared line.
const share0=x=>x<1?'1% 미만':x+'%';
function reference(input,findings){const table=[],notes=[];
  const list=Object.entries(input.sources).sort((a,b)=>b[1].total-a[1].total);
  // 한도를 쓴 양 column: the source's share of all sources together (one price unit, so sources compare); models: shares
  // within the source; a model without a listed price shows its tokens and stays out of the shares
  const grand=list.reduce((n,[,s])=>n+(s.total>0?s.total:0),0);
  for(const [,s] of list){const known=s.byModel.slice(0,4).map(m=>m.label+' '+share0(m.share)),unp=(s.unpriced||[]).slice(0,2).map(m=>m.label+' 가격 미상('+fmt(m.tokens)+' 토큰)');
    table.push({source:s.name,used:s.total>0?P(pct1(s.total,grand)):'가격 미상',hit:s.hitPct+'%',models:[...known,...unp].join(', ')});}
  const unknown=[...new Set(list.flatMap(([,s])=>(s.unpriced||[]).map(m=>m.label)))];
  if(unknown.length){const u=unknown.slice(0,6);notes.push(u.join(', ')+eun(u[u.length-1])+' 공개 요금을 찾지 못해 가격 미상으로 두고 비율에서 뺐어요.');}
  for(const [,s] of list){if(s.ttlAssumed==='1h')notes.push(`${s.name}${eun(s.name)} 캐시 수명이 기록에 없지만 10분 넘게 쉬어도 캐시가 남아 있어 새로 저장(캐시)을 1시간 기준 2배로 셌어요.`);
    else if(s.ttlUnknown)notes.push(`${s.name}${eun(s.name)} 캐시 수명이 기록에 없어 새로 저장(캐시)을 5분 기준 1.25배로 셌어요.`);}
  for(const [group,keys] of COMPACT_GROUPS){if(findings.some(f=>f.id==='compact-'+group))continue;
    const src=keys.map(k=>input.sources[k]).filter(s=>s&&s.compactCurve);if(!src.length){const any=keys.map(k=>input.sources[k]).filter(s=>s&&s.compact.n>=3);if(any.length)notes.push(`${group} 자동 압축 기준 설정을 읽지 못해 다른 기준은 계산하지 않았어요.`);continue;}
    const p=pickCompaction(src.map(s=>s.compactCurve));
    if(!p){notes.push(`${group} 자동 압축은 기록 재계산으로 기준을 바꿔도 한도를 쓴 양이 거의 같아요.`);continue;}
    const u=src[0].compactCurve.unit==='%'?'%':' 토큰',pick=u==='%'?p.pick:fmt(p.pick),sgn=v=>v>=0?`${P(v)} 덜`:`${P(-v)} 더`;
    notes.push(`실험해 볼 거리: ${group} 자동 압축 기준이 ${pick}${u}였다면 기록 재계산으로 ${src.map((s,i)=>`${s.name} ${sgn(p.per[i].saveShare)}`).join(', ')} 썼어요. 요약을 만드는 비용은 넣었지만 요약 뒤 다시 찾아 읽는 양은 기록에 없어요. 요약마다 5만 토큰씩 다시 읽으면 ${src.map((s,i)=>`${s.name} ${sgn(p.per[i].saveRereadShare)}`).join(', ')} 써요.`);}
  if(input.excluded.length)notes.push(`${input.excluded.join(', ')}${eun(input.excluded[input.excluded.length-1])} 캐시 기록이 없어 셀 수 없어요.`);
  return {table,notes:notes.slice(0,6)};}
// per-source cache lifetime evidence, kept in the result for checking (not shown as advice)
function evidenceOf(input){const out={};for(const [,s] of Object.entries(input.sources))if(s.gapTable)out[s.name]={lifetime:s.lifetime,from:s.lifeFrom,confirmed:!!s.lifeConfirmed,gaps:s.gapTable.map(b=>({from:b.from,to:b.to,n:b.n,hitPct:b.hitPct})),coldRestarts:s.cold.n,missesInsideLifetime:s.coldInside?s.coldInside.n:0};return out;}

// ---- 4. guardrails on model text ----
const BANNED=[
  {re:/(쉬|공백|만료|휴식)[^.。]{0,30}(\/compact|압축)/,unless:/말고|말아|마세요|않|대신 새|정리해/,why:'contradicts guidance: compacting after the cache expired is the most expensive case'},
  {re:/다시\s*읽[^.。]{0,25}(줄이|줄여|줄일|아끼|아껴|피하|피해|낮추|낮춰)/,why:'re-reads are cheap cache hits; never advise cutting them'},
  {re:/(캐시|재사용|적중)[^.。]{0,15}(줄이|줄여|아끼|아껴|낭비)/,why:'cache use is good; never advise using less of it'},
  {re:/(대화|작업)[^.。]{0,12}(나누|나눠|쪼개|분리)/,why:'splitting conversations because of re-reads is not advised'},
  {re:/(sonnet|haiku|opus|소넷|하이쿠|오퍼스|싼 모델|작은 모델|가벼운 모델)/i,why:'model choice is not waste; no model advice'},
  {re:/(원|달러|\$|USD|비용이\s*\d)/,why:'no money amounts'},
  {re:/[\u00b7\u2022\u2219]/,why:'no middle dots (WRITING.md): commas, line breaks or sentences'},
  {re:/(부담|비중|가중)/,why:'owner wording: say "한도를 쓴 양", not 부담, 비중 or 가중'},
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
        else if(!numbersOf(text).some(n=>(f.shares||[]).includes(n)))reason='share of total missing';
        else if(/추정/.test(text))reason='the page says "요금 기준 추정" once, not in each item';
        else if((text.match(/1% 미만/g)||[]).length<([f.fixed.title,f.fixed.why,f.fixed.how].join(' ').match(/1% 미만/g)||[]).length)reason='a share under 1% must stay "1% 미만"';
        else if(f.fixed.criterion===1&&!/새 대화/.test(it.how))reason='cold restart advice must keep the new-conversation step';
        else if(f.facts.source&&!it.title.includes(f.facts.source))reason='title must name the source';
        else if(f.fixed.criterion===1&&!/최대/.test(it.title+it.why))reason='cold restart saving is an upper bound and must say 최대';
        else if(f.fixed.criterion===2&&!/처음/.test(it.how))reason='model switch advice must say to choose at the start';}}
    if(reason)dropped.push({title:String(it&&it.title||'').slice(0,80),reason});else kept.push({id:f.id,criterion:[f.fixed.criterion],evidence:f.evidence,title:it.title.trim(),why:it.why.trim(),how:it.how.trim()});}
  return {kept:kept.slice(0,5),dropped};}

// ---- 5. the model call ----
function prompt(findings){return `아래는 한 사람의 AI 토큰 사용 기록을 코드로 점검해 이미 판정한 결과예요(대화 내용 없음, 집계값만).
판정 원칙(반드시 지켜요):
- 캐시 다시 읽기는 좋은 거예요. 새 입력의 약 0.1배로 쳐서, 다시 읽은 양이 많거나 몇 배라는 이유로 줄이라고 하지 말아요. 대화를 나누라고 하지 말아요.
- 숫자는 "한도를 쓴 양"의 비율(%)이에요(요금 기준 추정: 모델마다 공개 API 요금으로 새 입력, 캐시 저장(Claude는 새 입력 요금의 1.25배(5분) 또는 2배(1시간), 그 밖은 1배), 다시 읽기(캐시), AI가 쓴 답을 셌어요. ${PRICE_NOTE}).
- 말투: "한도를 쓴 양", "모델별로 한도를 쓴 양"처럼 쉬운 말로 써요. "부담", "비중", "가중"이라는 말은 쓰지 말아요.
- 낭비로 보는 건 캐시를 잃은 경우뿐이에요: 오래 쉬어 캐시가 만료된 뒤 새로 저장(캐시), 대화 중간 모델 전환, 자동 압축 뒤 다시 저장.
- 어떤 모델을 쓰는지는 낭비가 아니에요. 모델 이름(Opus, Sonnet, Haiku 등)을 꺼내거나 더 작은 모델로 바꾸라고 하지 말아요.
- 압축 기준은 facts의 direction 방향으로만 말해요(lower=낮추기, higher=올리기).
규칙:
- 아래 항목만 다뤄요. 항목을 더하거나 빼지 말고, id를 그대로 써요.
- 숫자는 facts와 draft에 있는 값만 쓰고 새로 계산하지 말아요. 각 항목에 한도를 쓴 양 숫자와 전체 대비 비율(%)을 꼭 넣어요.
- 비용이나 돈은 말하지 말아요. 서로 다른 출처(source)의 숫자를 더하지 말아요.
- 쉬었다 돌아온 뒤 압축하라고 하지 말아요(그때가 가장 비싸요).
- "요금 기준 추정"은 화면 아래에 이미 한 번 적혀 있어요. 항목에는 "추정"이라는 말을 쓰지 말아요(규칙 8).
- 제목에는 출처 이름(facts.source)을 꼭 넣어요.
- 쉬었다 이어 쓴 항목의 비율은 다 피할 수 없는 최대치라 "최대"를 꼭 남겨요.
- draft의 "1% 미만"은 그대로 써요. 캐시 만료 항목의 how에는 "새 대화"를, 모델 전환 항목의 how에는 "처음"을 꼭 남겨요.
화면 글쓰기 규칙(매번 따라요):
${writingRules()}

할 일: draft를 더 쉽고 긍정적인 한국어로 다듬어요. 캐시를 살려 쓰는 쪽으로, 짧게, 존댓말("~해요").
출력: JSON 배열만. [{"id":"...","title":"...","why":"...","how":"..."}]

항목(코드 판정, 한도를 많이 쓴 순):
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
  const input=buildInput({snap,names,indexPath,home,now}),findings=rules(input),ref=reference(input,findings);
  const base={at:new Date(now).toISOString(),basis:BASIS,table:ref.table,notes:ref.notes,evidence:evidenceOf(input),weights:Object.fromEntries(Object.entries(input.sources).map(([k,s])=>[k,{write:s.writeRatio,life:s.lifetime}])),rules:'cache-v2'};
  if(!findings.length)return {...base,model:null,items:[],dropped:[],findings:0};
  const ans=useModel?await ask(findings,{workDir,home}):{model:null,items:[]};
  const {kept,dropped}=validate(ans.items,findings);
  const seen=new Set(),items=[];for(const k of kept)if(!seen.has(k.id)){seen.add(k.id);items.push({...k,by:'model'});}
  for(const f of findings)if(!seen.has(f.id)){seen.add(f.id);items.push({id:f.id,...f.fixed,criterion:[f.fixed.criterion],evidence:f.evidence,by:'rule'});}
  const rank=new Map(findings.map((f,i)=>[f.id,i]));items.sort((a,b)=>rank.get(a.id)-rank.get(b.id));
  return {...base,model:items.some(i=>i.by==='model')?ans.model:null,items:items.slice(0,5),dropped,findings:findings.length};}

module.exports={PRICE_TABLE,PRICE_CHECKED,coldSaving,writingRules,buildInput,analyze,replay,compactionCurve,pickCompaction,rules,reference,evidenceOf,gapTable,lifetimeOf,compactionSolid,GAP_BUCKETS,SUMMARY_OUT,REREAD_TEST,validate,habitCheck,prompt,BANNED,PRICES,PRICE_NOTE,BASIS,numbersOf,priceFor};
