'use strict';
// Tests for the AI habit check (cache-aware rules): weighting, mechanical cache-loss detection, the compaction replay,
// guardrails on model text, and the whole check on a temporary index without a model or with a fake one.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const h=require('./habit-check.cjs');let n=0;const ok=m=>{n++;console.log('PASS '+m);};
const M=60000,T0=Date.parse('2026-10-20T00:00:00Z');

// ---- synthetic request records ----
// one conversation: grows by `step` per request, 1 minute apart; `cold` = indexes resumed after `idle` minutes with the
// cache gone; `switchAt` = indexes where the model changes; compacts to `post` when it passes `limit`
function conv({session,model='claude-opus-5-5',n=300,start=30000,step=2000,cold=[],idle=90,switchAt=[],limit=Infinity,post=75000,out=500,t0=T0,openai=false}){
  const rows=[];let ctx=start,at=t0,m=model,prevCtx=0;
  for(let i=0;i<n;i++){let r;at+=(cold.includes(i)?idle:1)*M;if(switchAt.includes(i))m=m===model?'claude-sonnet-5-5':model;
    if(i===0)r={input:openai?ctx:0,cacheRead:0,cacheCreate:openai?0:ctx};
    else if(ctx+step>limit){ctx=post;r={input:openai?post-13000:0,cacheRead:13000,cacheCreate:openai?0:post-13000};}
    else if(cold.includes(i)||switchAt.includes(i)){ctx+=step;r={input:openai?ctx-5000:0,cacheRead:5000,cacheCreate:openai?0:ctx-5000};}
    else{ctx+=step;r={input:openai?step:0,cacheRead:prevCtx,cacheCreate:openai?0:ctx-prevCtx};}
    prevCtx=ctx;rows.push({session,model:m,at,output:out,cw5m:null,cw1h:null,...r});}
  return rows;}

// 1. weighting: the documented price table
{const p=h.priceFor('claude_aside_local','claude-opus-5-5');assert.equal(p.out,5);assert.equal(p.read,0.1);assert.equal(p.write5m,1.25);assert.equal(p.write1h,2);
 assert.equal(h.priceFor('codex_aside_local','gpt-5.6-sol').out,8);assert.equal(h.priceFor('codex_aside_local','gpt-6-astra').out,4,'unknown OpenAI model: 4 and a note');
 assert.equal(h.priceFor('codex_aside_local','gpt-6-astra').known,false);assert.equal(h.priceFor('grok_aside_local','grok-4.7').read,0.25);
 assert.ok(/공개 API 요금 비율 기준, 구독 한도 실제 차감 방식은 비공개라 추정/.test(h.PRICE_NOTE));
 const one=[{session:'s',model:'claude-opus-5-5',at:T0,input:100,output:10,cacheRead:1000,cacheCreate:400,cw5m:100,cw1h:200}];
 const a=h.analyze('claude_cli_local',one);assert.equal(a.total,100+100*1.25+200*2+100*1.25+1000*0.1+10*5,'5-minute, 1-hour and unrecorded writes, read 0.1, output 5');
 assert.equal(a.hitPct,Math.round(100*1000/1500),'hit rate = re-read share of input');
 const b=h.analyze('codex_aside_local',[{session:'s',model:'gpt-6-astra',at:T0,input:100,output:10,cacheRead:1000,cacheCreate:0}]);assert.equal(b.total,100+100+40);assert.deepEqual(b.outUnknown,['GPT-6 Astra']);
 ok('weighting follows the price table (writes by lifetime, reads 0.1, output ratio, unknown model 4)');}

// 2. detection: cold restarts after an idle gap, model switches, compactions; re-reads are hits, not events
{const rows=[...conv({session:'a',n:200,cold:[50,120],switchAt:[160]}),...conv({session:'b',n:500,limit:850000,post:75000,step:3000})];
 const a=h.analyze('claude_aside_local',rows);
 assert.equal(a.cold.n,2);assert.equal(a.switch.n,1);assert.ok(a.compact.n>=1);assert.equal(a.lifetime,null,'no gap data between 1 and 90 minutes: lifetime not guessed');
 assert.ok(a.hitPct>=90,'long conversations with a living cache have a high hit rate');
 // measured lifetime: re-reads survive 40-minute gaps, 70-minute gaps lose the cache
 const g=[];let at=T0;const push=(gap,hit,i)=>{at+=gap*M;g.push({session:'g',model:'claude-opus-5-5',at,input:0,output:100,cacheRead:hit?100000:5000,cacheCreate:hit?1000:96000});};
 push(0,false);for(let i=0;i<10;i++){push(40,true);push(70,false);push(1,true);}
 assert.equal(h.analyze('claude_aside_local',g).lifetime,45,'the last 5-minute window where re-reads still won (40-45), not a guess beyond it');
 const rec=[{session:'r',model:'claude-opus-5-5',at:T0,input:0,output:1,cacheRead:0,cacheCreate:50000,cw5m:0,cw1h:50000}];assert.equal(h.analyze('claude_cli_local',rec).lifetime,60,'1-hour writes recorded');
 ok('detection: cold restart, model switch, compaction, cache lifetime (recorded or measured)');}

// 3. rules: only mechanical cache loss, ranked by 부담, with share of the source total
const settings={aside:{enabled:true,thresholdPercent:85}};
function inputOf(sets){const input={sources:{},excluded:['Antigravity'],settings};for(const [ds,rows] of Object.entries(sets)){const a=h.analyze(ds,rows);const st=ds.endsWith('_aside_local')?{percent:85}:null;const c=h.compactionCurve(a,st);delete a.sessions;input.sources[ds]={name:{claude_aside_local:'Aside Claude',codex_aside_local:'Aside Codex',claude_cli_local:'Claude Code'}[ds],...a,compactCurve:c};}return input;}
const heavyCold=Array.from({length:30},(_,i)=>conv({session:'c'+i,n:120,cold:[40,80],t0:T0+i*864e5/2}));
const big=Array.from({length:2},(_,i)=>conv({session:'L'+i,n:900,step:2500,limit:850000,post:75000,t0:T0+i*864e5}));
const subagents=Array.from({length:40},(_,i)=>conv({session:'h'+i,n:20,model:'claude-opus-5-5',t0:T0+i*3600e3}));   // many short Opus helpers: not waste
const input=inputOf({claude_aside_local:[...heavyCold.flat(),...big.flat(),...subagents.flat()],codex_aside_local:conv({session:'x',n:200,model:'gpt-5.6-sol',openai:true})});
const F=h.rules(input);
{const ids=F.map(f=>f.id);
 assert.ok(ids.includes('cold-claude_aside_local'),'cold restarts flagged');assert.ok(ids.includes('compact-Aside'),'compaction direction from the replay');
 assert.ok(!ids.some(i=>/helper|shortopus|reread|live|long|claudemd/.test(i)),'no old re-read, helper, long-conversation or CLAUDE.md items');
 for(const f of F){const t=f.fixed.title+f.fixed.why+f.fixed.how;assert.ok(!/(Sonnet|Haiku|Opus)/.test(t),'no model advice: '+f.id);assert.ok(!/다시 읽기 줄|나누/.test(t),'no re-read cutting: '+f.id);
   assert.ok(f.shares.some(s=>t.includes(s+'%')),'share of total shown: '+f.id);assert.ok(/한도를/.test(t)&&!/부담|비중|가중/.test(t),'한도를 쓴 양 shown, old words gone: '+f.id);}
 for(let i=1;i<F.length;i++)assert.ok(F[i-1].impact>=F[i].impact,'ranked by 부담');
 const c=F.find(f=>f.id==='compact-Aside');assert.ok(c.facts.pick>=50,'replay candidates stop at half the window');assert.equal(c.facts.direction,c.facts.pick<85?'lower':'higher');
 const cold=F.find(f=>f.id==='cold-claude_aside_local');assert.ok(/캐시가 살아 있을 때/.test(cold.fixed.title)&&/새 대화/.test(cold.fixed.how));
 ok('rules: cold restart and compaction items, ranked by 부담, share shown, no model or re-read advice');}
{// a high re-read multiple alone is not waste: one long healthy conversation, cache always alive
 const healthy=inputOf({claude_aside_local:conv({session:'ok',n:300,step:1500})});assert.deepEqual(h.rules(healthy),[],'well-used cache: no items');
 const info=h.infoLines(healthy,[]);assert.ok(/캐시 적중 \d+%/.test(info[0].title)&&/적중률이 높을수록 좋아요/.test(info[0].why),'hit rate shown positively');
 assert.ok(/모델별로 한도를 쓴 양 \(/.test(info[0].why)&&!/부담|비중/.test(info[0].title+info[0].why),'model mix is a neutral line in plain words');assert.ok(info.some(i=>/지원 안 함/.test(i.title)),'unsupported sources named');
 assert.ok(/1\.25배\(5분 기준\)/.test(info[0].why),'unknown lifetime: 1.25 and said so');
 // small cold-restart cost is not flagged
 const few=inputOf({claude_aside_local:[...conv({session:'big',n:2000,step:300}),...conv({session:'one',n:60,cold:[30]})]});assert.ok(!h.rules(few).some(f=>f.id.startsWith('cold')),'below 3% of the total: no item');
 // model switches below the floor are ignored, above it flagged with the right advice
 const sw=inputOf({claude_aside_local:conv({session:'s',n:200,switchAt:[40,80,120,160]})});const s=h.rules(sw).find(f=>f.id.startsWith('switch'));assert.ok(s&&/처음에 정하기/.test(s.fixed.title));
 ok('rules: healthy cache gives no items; neutral info lines; thresholds; model switch advice');}
{// replay: lowering helps when re-reading near the top dominates; it does not when compaction itself is expensive and growth slow
 const a=h.analyze('claude_aside_local',big.flat());const c=h.compactionCurve(a,{percent:85});assert.ok(c.replayCompactions>=a.compact.n-2&&c.replayCompactions<=a.compact.n+2,'replay at the current point reproduces the recorded compactions');
 const lower=c.results.filter(r=>r.lower);assert.ok(lower.every(r=>r.n>=c.replayCompactions),'lowering never reduces compactions');
 const p=h.pickCompaction([c]);assert.ok(p&&p.lower);
 const flat=conv({session:'f',n:200,step:20000,limit:850000,post:800000});const b=h.analyze('claude_aside_local',flat);const cf=h.compactionCurve(b,{percent:85});assert.equal(cf,null,'compaction that barely shrinks the context: no advice');
 ok('compaction replay: reproduces the record, direction reasoned, no advice when unsupported');}

// 4. guardrails on model text
{const f=F.find(x=>x.id==='cold-claude_aside_local'),good={id:f.id,title:f.fixed.title,why:f.fixed.why,how:f.fixed.how};
 for(const x of F)assert.deepEqual(h.validate([{id:x.id,...x.fixed}],F).dropped,[],'fixed text passes its own guardrails: '+x.id);
 const cases=[
  [good,0],
  [{...good,why:good.why+' 다시 읽은 양이 87배예요.'},1],                       // invented multiple
  [{...good,how:'다시 읽기를 줄이려고 작업 단위로 대화를 나눠요.'},1],              // old framing
  [{...good,how:'하위 작업은 Sonnet으로 맡겨요.'},1],                              // model advice
  [{...good,how:'캐시 읽기를 아껴요.'},1],                                         // cache use is good
  [{...good,how:'쉬었다 돌아오면 /compact로 줄이고 이어가요.'},1],                   // contradicts guidance
  [{...good,how:'월 10달러 아껴요.'},1],
  [{...good,how:good.how+' 한도 부담 비중이 커요.'},1],                          // old wording
  [{...good,how:good.how.replace('. ',', 그리고 ')+' 캐시 · 토큰'},1],                // middle dot                                            // money
  [{...good,why:'readRatio 0.1이에요. '+good.why},1],                               // field name
  [{...good,why:'캐시가 만료돼 다시 저장했어요.'},1],                                 // share of total missing
  [{...good,id:'reread-x'},1],
  [{...good,why:'요금 기준 추정으로 보면 '+good.why},1],                                   // estimate said once on the page
  [{...good,how:'60분 안에 이어 쓰면 좋아요. 쉬기 전에 메모해 두세요.'},1],                // drops the new-conversation step                                                      // not a finding
  [{title:'x'},1]];
 for(const [it,drop] of cases)assert.equal(h.validate([it],F).dropped.length,drop,JSON.stringify(it).slice(0,90));
 const c=F.find(x=>x.id==='compact-Aside');const wrong=c.facts.direction==='lower'?'올려요':'낮춰요';assert.equal(h.validate([{id:c.id,title:c.fixed.title,why:c.fixed.why,how:'기준을 '+c.facts.pick+'%로 '+wrong+'.'}],F).dropped.length,1,'direction must follow the replay');
 const p=h.prompt(F);for(const s of ['캐시 다시 읽기는 좋은 거예요','대화를 나누라고 하지 말아요','모델 이름','direction',h.PRICE_NOTE])assert.ok(p.includes(s),'prompt states: '+s);
 assert.ok(!/하위 작업|다시 읽기 줄이기/.test(p),'prompt carries no old framing');
 assert.ok(p.includes(h.writingRules())&&/가운데 점/.test(h.writingRules())&&/해요체/.test(h.writingRules()),'prompt carries WRITING.md every time');
 ok('guardrails: invented numbers, re-read cutting, model advice, money, field names, share, direction; prompt principles');}

// 5. the whole check on a temporary index
(async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'habit-'));const idx=path.join(dir,'ix.sqlite');const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(idx);
  db.exec('CREATE TABLE chosen(dataset TEXT,key TEXT,at INTEGER,day TEXT,hour INTEGER,project TEXT,session TEXT,model TEXT,attribution TEXT,app TEXT,cw5m INTEGER,cw1h INTEGER,input INTEGER,output INTEGER,cacheRead INTEGER,cacheCreate INTEGER,reasoning INTEGER,total INTEGER,records INTEGER,dups INTEGER,conflicts INTEGER)');
  const ins=db.prepare('INSERT INTO chosen(dataset,key,at,day,session,model,cw5m,cw1h,input,output,cacheRead,cacheCreate,total,records) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,1)');let k=0;
  const now=Date.parse('2026-10-29T12:00:00Z'),shift=now-T0-12*864e5;
  for(const r of [...heavyCold.flat(),...big.flat()]){const at=r.at+shift;ins.run('claude_aside_local',String(k++),at,new Date(at).toISOString().slice(0,10),r.session,r.model,null,null,r.input,r.output,r.cacheRead,r.cacheCreate,r.input+r.output+r.cacheRead+r.cacheCreate);}
  ins.run('antigravity_local','ag',now,'2026-10-29','g','unknown',null,null,10,1,5,0,11);db.close();
  const home=path.join(dir,'home');fs.mkdirSync(path.join(home,'.aside','u','0'),{recursive:true});fs.writeFileSync(path.join(home,'.aside','u','0','settings.json'),JSON.stringify({compaction:{enabled:true,thresholdPercent:85}}));
  const snap={datasets:[],period:{to:'2026-10-29'}};
  const r=await h.habitCheck({snap,names:{},indexPath:idx,home,useModel:false,now});
  assert.ok(r.items.length>=2&&r.items.every(i=>i.by==='rule'),'rule texts without a model');assert.ok(r.info.length>=2&&r.basis.includes('요금 기준 추정')&&!/부담|비중|가중|[\u00b7\u2022\u2219]/.test(r.basis+JSON.stringify(r.info)+JSON.stringify(r.items)));
  assert.ok(/공개 API 요금 비율 기준, 구독 한도 실제 차감 방식은 비공개라 추정/.test(fs.readFileSync(path.join(__dirname,'habit-check.cjs'),'utf8')),'source note kept in code');
  assert.ok(r.info.some(i=>/Antigravity: 한도를 쓴 양은 지원 안 함/.test(i.title)),'Antigravity excluded with 지원 안 함');
  // a model that tries the old framing is overruled; a good rewording is kept
  const ask=async F=>({model:'Claude Haiku',items:[{id:F[0].id,title:'다시 읽기 줄이기',why:'87배예요.',how:'대화를 나눠요.'},{id:F[1].id,title:F[1].fixed.title+'!',why:F[1].fixed.why,how:F[1].fixed.how}]});
  const r2=await h.habitCheck({snap,names:{},indexPath:idx,home,now,ask});
  assert.equal(r2.dropped.length,1);assert.equal(r2.model,'Claude Haiku');assert.ok(r2.items.some(i=>i.by==='model')&&r2.items.some(i=>i.by==='rule'));
  assert.ok(!r2.items.some(i=>/다시 읽기 줄이기|나눠/.test(i.title+i.how)),'old framing never reaches the page');
  assert.deepEqual(r2.items.map(i=>i.id),r.items.map(i=>i.id),'order stays by 부담');
  const r3=await h.habitCheck({snap:{datasets:[]},names:{},useModel:false,home:os.tmpdir()});assert.equal(r3.items.length,0,'no data, no items');
  fs.rmSync(dir,{recursive:true,force:true});ok('whole check: index in, rule texts, model overruled where it breaks the principles');
  console.log('RESULT '+n+' habit-check tests passed');})().catch(e=>{console.error(e);process.exitCode=1;});
