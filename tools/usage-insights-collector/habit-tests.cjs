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
 const ga=h.analyze('claude_aside_local',g);assert.equal(ga.lifetime,60,'first gap bucket under 50% hits (60-90)');assert.equal(ga.lifeConfirmed,false,'10 samples per bucket: 추정, not 기록으로 확인함');
 const rec=[{session:'r',model:'claude-opus-5-5',at:T0,input:0,output:1,cacheRead:0,cacheCreate:50000,cw5m:0,cw1h:50000}];assert.equal(h.analyze('claude_cli_local',rec).lifetime,60,'1-hour writes recorded');
 ok('detection: cold restart, model switch, compaction, cache lifetime (recorded or measured)');}

// 2b. gap buckets: hit rate per idle-gap bucket, lifetime = first bucket under 50%, 기록으로 확인함 only with 20+ samples
{const mk=(spec)=>{const g=[];let at=T0;g.push({session:'b',model:'claude-opus-5-5',at,input:0,output:100,cacheRead:0,cacheCreate:100000});
   for(const [gap,hit] of spec){at+=gap*M;g.push({session:'b',model:'claude-opus-5-5',at,input:0,output:100,cacheRead:hit?100000:5000,cacheCreate:hit?1000:96000});at+=M;g.push({session:'b',model:'claude-opus-5-5',at,input:0,output:100,cacheRead:100000,cacheCreate:1000});}return g;};
 const rep=(n,x)=>Array.from({length:n},()=>x);
 const t=h.gapTable([1,7,7,12,95],[8,61,95,95]);assert.deepEqual(t.map(b=>[b.from,b.n,b.hitPct]),[[0,1,100],[5,3,67],[10,1,100],[20,0,null],[30,0,null],[45,0,null],[60,1,0],[90,3,33]],'buckets 0-5, 5-10, 10-20, 20-30, 30-45, 45-60, 60-90, 90+');
 const a=h.analyze('codex_aside_local',mk([...rep(25,[7,true]),...rep(25,[15,false])]).map(r=>({...r,model:'gpt-6-astra',input:r.cacheCreate,cacheCreate:0})));
 assert.equal(a.lifetime,10);assert.equal(a.lifeConfirmed,true,'25 samples on both sides of the drop: 기록으로 확인함');
 const b=h.analyze('codex_aside_local',mk([...rep(25,[7,true]),...rep(6,[15,false])]).map(r=>({...r,model:'gpt-6-astra',input:r.cacheCreate,cacheCreate:0})));
 assert.equal(b.lifetime,10);assert.equal(b.lifeConfirmed,false,'6 samples past the drop: 추정');
 assert.equal(b.cold.n,6,'cold restarts are misses at or past the lifetime');
 const c=h.analyze('codex_aside_local',mk([...rep(25,[7,true]),...rep(4,[7,false]),...rep(25,[15,false])]).map(r=>({...r,model:'gpt-6-astra',input:r.cacheCreate,cacheCreate:0})));
 assert.equal(c.cold.n,25);assert.equal(c.coldInside.n,4,'misses inside the lifetime are counted apart, not as advice');
 // Claude with no recorded lifetime but hits after 10 to 30 minutes: a 1-hour cache, writes 2x
 const d=h.analyze('claude_aside_local',mk([...rep(25,[15,true]),...rep(25,[70,false])]));assert.equal(d.ttlAssumed,'1h');assert.equal(d.writeRatio,2);assert.equal(d.lifetime,60);
 const e=h.analyze('claude_aside_local',mk(rep(25,[70,false])));assert.equal(e.ttlAssumed,null,'no evidence past 10 minutes: 1.25');
 // same-session, same-model only: a model change is a switch, never a cache-lifetime sample
 const s=mk(rep(25,[7,true]));s[2].model='claude-sonnet-5-5';const sa=h.analyze('claude_aside_local',s);assert.equal(sa.gapTable.find(x=>x.from===5).n,24);
 ok('gap buckets: hit rate per bucket, lifetime at the first bucket under 50%, 20+ samples for 기록으로 확인함, misses split at the lifetime');}

// 2c. OpenAI weighting: a miss is new input at 1x (no cache-write charge), cached input 0.1x; Grok the same with 0.25x
{const p=h.priceFor('codex_aside_local','gpt-6.1-terra');assert.equal(p.write,1);assert.equal(p.read,0.1);assert.equal(p.known,false,'output price unknown, input rule known');
 assert.equal(h.priceFor('codex_cli_local','o4-mini').write,1);assert.equal(h.priceFor('grok_aside_local','grok-5').read,0.25);assert.equal(h.priceFor('grok_aside_local','grok-5').write,1);
 const miss=[{session:'o',model:'gpt-5.6-sol',at:T0,input:0,output:0,cacheRead:100000,cacheCreate:0},{session:'o',model:'gpt-5.6-sol',at:T0+30*M,input:101000,output:0,cacheRead:0,cacheCreate:0}];
 const a=h.analyze('codex_aside_local',miss);assert.equal(a.total,100000*0.1+101000,'miss = 1x input, no write surcharge');assert.equal(a.writeRatio,1);
 const cw=h.analyze('codex_aside_local',[{session:'o',model:'gpt-5.6-sol',at:T0,input:10,output:0,cacheRead:0,cacheCreate:1000}]);assert.equal(cw.total,10+1000,'reported cache writes also 1x');
 ok('OpenAI and Grok weighting: miss 1x input, cached 0.1x (Grok 0.25x), no cache-write surcharge');}

// 2d. compaction: the summary call is counted; advice only when the saving is 10%+ and survives the unknowns
{const big2=Array.from({length:2},(_,i)=>conv({session:'Q'+i,n:900,step:2500,limit:850000,post:75000,t0:T0+i*864e5}));
 const a=h.analyze('claude_aside_local',big2.flat());
 const T=a.compact.pre,r0=h.replay(a,T,{summaryOut:0}),r1=h.replay(a,T),rf=h.replay(a,T,{summaryIn:'full'}),rr=h.replay(a,T,{reread:h.REREAD_TEST});
 assert.equal(Math.round(r1.total-r0.total),Math.round(r1.n*h.SUMMARY_OUT*a.outRatio),'summary output counted at the output ratio');
 assert.ok(rf.total>r1.total,'a summary call that reads at 1x costs more');assert.ok(rr.total>r1.total,'re-reading after each summary costs more');
 const solid={per:[{saveShare:20,saveFullShare:18,saveRereadShare:19}]},thin={per:[{saveShare:12,saveFullShare:5,saveRereadShare:-17}]},small={per:[{saveShare:8,saveFullShare:8,saveRereadShare:8}]};
 assert.equal(h.compactionSolid(solid),true);assert.equal(h.compactionSolid(thin),false,'depends on the unknowns');assert.equal(h.compactionSolid(small),false,'under 10%');
 // one Aside setting covers both sources: one fragile source keeps it out of the advice, and it becomes 실험해 볼 거리
 const inp={sources:{claude_aside_local:{name:'Aside Claude',...a,cold:{n:0,burden:0},switch:{n:0,burden:0},compactCurve:{current:85,unit:'%',results:[{label:50,lower:true,n:9,save:2e6,saveShare:20,saveFullShare:18,saveRereadShare:20}]}},
   codex_aside_local:{name:'Aside Codex',...a,cold:{n:0,burden:0},switch:{n:0,burden:0},outUnknown:[],compactCurve:{current:85,unit:'%',results:[{label:50,lower:true,n:9,save:1e6,saveShare:10,saveFullShare:4.4,saveRereadShare:-17.4}]}}},excluded:[],settings:{}};
 const F2=h.rules(inp);assert.ok(!F2.some(f=>f.id.startsWith('compact')),'fragile saving: no settings advice');
 const notes=h.reference(inp,F2).notes.join(' ');assert.ok(/실험해 볼 거리: Aside 자동 압축 기준이 50%였다면/.test(notes)&&/Aside Codex 17% 더/.test(notes)&&/기록에 없어요/.test(notes),'shown only as 실험해 볼 거리 with the caveat');
 assert.ok(!/(낮춰요|올려요|설정에서)/.test(notes),'never phrased as a settings instruction');
 inp.sources.codex_aside_local.compactCurve.results[0]={...inp.sources.codex_aside_local.compactCurve.results[0],saveShare:15,saveFullShare:14,saveRereadShare:12};
 const F3=h.rules(inp),c3=F3.find(f=>f.id==='compact-Aside');assert.ok(c3&&c3.evidence==='추정'&&/요약을 만드는 비용/.test(c3.fixed.why),'solid saving: advice, tagged 추정');
 ok('compaction: summary call counted, gated at 10% and on the unknowns, otherwise 실험해 볼 거리 only');}


// 3. rules: only mechanical cache loss, ranked by 부담, with share of the source total
const settings={aside:{enabled:true,thresholdPercent:85}};
function inputOf(sets){const input={sources:{},excluded:['Antigravity'],settings};for(const [ds,rows] of Object.entries(sets)){const a=h.analyze(ds,rows);const st=ds.endsWith('_aside_local')?{percent:85}:null;const c=h.compactionCurve(a,st);delete a.sessions;input.sources[ds]={name:{claude_aside_local:'Aside Claude',codex_aside_local:'Aside Codex',claude_cli_local:'Claude Code'}[ds],...a,compactCurve:c};}return input;}
const heavyCold=Array.from({length:30},(_,i)=>conv({session:'c'+i,n:120,cold:[40,80],t0:T0+i*864e5/2}));
const big=Array.from({length:2},(_,i)=>conv({session:'L'+i,n:900,step:2500,limit:850000,post:75000,t0:T0+i*864e5}));
const subagents=Array.from({length:40},(_,i)=>conv({session:'h'+i,n:20,model:'claude-opus-5-5',t0:T0+i*3600e3}));   // many short Opus helpers: not waste
const input=inputOf({claude_aside_local:[...heavyCold.flat(),...big.flat(),...subagents.flat()],codex_aside_local:conv({session:'x',n:200,model:'gpt-5.6-sol',openai:true})});
const F=h.rules(input);
{const ids=F.map(f=>f.id);
 assert.ok(ids.includes('cold-claude_aside_local'),'cold restarts flagged');assert.ok(F.every(f=>f.evidence==='기록으로 확인함'||f.evidence==='추정'),'every item has an evidence tag');
 assert.ok(!ids.some(i=>/helper|shortopus|reread|live|long|claudemd/.test(i)),'no old re-read, helper, long-conversation or CLAUDE.md items');
 for(const f of F){const t=f.fixed.title+f.fixed.why+f.fixed.how;assert.ok(!/(Sonnet|Haiku|Opus)/.test(t),'no model advice: '+f.id);assert.ok(!/다시 읽기 줄|나누/.test(t),'no re-read cutting: '+f.id);
   assert.ok(f.shares.some(s=>t.includes(s+'%')),'share of total shown: '+f.id);assert.ok(/한도를/.test(t)&&!/부담|비중|가중/.test(t),'한도를 쓴 양 shown, old words gone: '+f.id);}
 for(let i=1;i<F.length;i++)assert.ok(F[i-1].impact>=F[i].impact,'ranked by 부담');
 const c=F.find(f=>f.id==='compact-Aside');if(c){assert.ok(c.facts.pick>=50,'replay candidates stop at half the window');assert.equal(c.facts.direction,c.facts.pick<85?'lower':'higher');assert.equal(c.evidence,'추정');}
 const cold=F.find(f=>f.id==='cold-claude_aside_local');assert.ok(/\d+분 안에 이어 쓰면 한도를 최대 \d+% 아껴요/.test(cold.fixed.title)&&/최대치/.test(cold.fixed.why)&&/새 대화/.test(cold.fixed.how),'upper bound wording');
 ok('rules: cold restart and compaction items, ranked by 부담, share shown, no model or re-read advice');}
{// a high re-read multiple alone is not waste: one long healthy conversation, cache always alive
 const healthy=inputOf({claude_aside_local:conv({session:'ok',n:300,step:1500})});assert.deepEqual(h.rules(healthy),[],'well-used cache: no items');
 const ref=h.reference(healthy,[]);assert.deepEqual(Object.keys(ref.table[0]),['source','used','hit','models']);assert.ok(/^\d+%$/.test(ref.table[0].hit),'hit rate in its own column');
 assert.ok(/Opus 5\.5 100%/.test(ref.table[0].models)&&!/부담|비중/.test(JSON.stringify(ref)),'model mix is a neutral cell in plain words');assert.ok(ref.notes.some(i=>/Antigravity는 캐시 기록이 없어/.test(i)),'unsupported sources named once');
 assert.ok(ref.notes.some(i=>/5분 기준 1\.25배/.test(i)),'unknown lifetime: 1.25 and said so');
 {const two=inputOf({claude_aside_local:conv({session:'a',n:50}),codex_aside_local:conv({session:'b',n:50,model:'gpt-6-astra',openai:true}),codex_cli_local:conv({session:'c',n:50,model:'gpt-6-astra',openai:true})});two.sources.codex_cli_local.name='Codex 앱';
  const r2=h.reference(two,[]);assert.equal(r2.table.length,3,'one row per source');assert.equal(r2.notes.filter(x=>/공개 요금이 없어/.test(x)).length,1,'unknown-price models noted once');
  const all=r2.notes.join(' ');for(const sent of all.split(/[.]/).map(x=>x.trim()).filter(Boolean))assert.equal(all.split(sent).length-1,1,'no repeated sentence: '+sent);}
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
  [{...good,title:'Aside Claude는 최대한 이어 써요',why:'캐시가 만료돼 다시 저장했어요.'},1],                                 // share of total missing
  [{...good,title:good.title.replace('최대 ',''),why:good.why.replace(/[^.]*최대치예요\. ?/,'')},1],      // drops the upper bound
  [{...good,title:good.title.replace(/^Aside Claude는 /,'')},1],                                     // title without the source                                 // share of total missing
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
  assert.ok(r.items.length>=1&&r.items.every(i=>i.by==='rule'&&/^(기록으로 확인함|추정)$/.test(i.evidence)),'rule texts without a model, each tagged');assert.ok(r.table.length>=1&&r.basis.includes('요금 기준 추정')&&!/부담|비중|가중|[\u00b7\u2022\u2219]/.test(r.basis+JSON.stringify(r.table)+JSON.stringify(r.notes)+JSON.stringify(r.items)));
  assert.ok(!/\n/.test(r.basis)&&r.basis.length<200,'shared explanation is one line');assert.ok(r.evidence&&r.evidence['Aside Claude']&&r.evidence['Aside Claude'].gaps.length===8,'gap table kept for checking');
  assert.ok(/공개 API 요금 비율 기준, 구독 한도 실제 차감 방식은 비공개라 추정/.test(fs.readFileSync(path.join(__dirname,'habit-check.cjs'),'utf8')),'source note kept in code');
  assert.ok(r.notes.some(i=>/Antigravity는 캐시 기록이 없어/.test(i)),'Antigravity excluded, said once');
  // a model that tries the old framing is overruled; a good rewording is kept
  const ask=async F=>({model:'Claude Haiku',items:[{id:F[0].id,title:'다시 읽기 줄이기',why:'87배예요.',how:'대화를 나눠요.'},...F.slice(1).map(f=>({id:f.id,title:f.fixed.title+'!',why:f.fixed.why,how:f.fixed.how}))]});
  const r2=await h.habitCheck({snap,names:{},indexPath:idx,home,now,ask});
  assert.equal(r2.dropped.length,1);assert.ok(r2.items.some(i=>i.by==='rule'));if(r.items.length>1)assert.ok(r2.model==='Claude Haiku'&&r2.items.some(i=>i.by==='model'));assert.ok(r2.items.every(i=>i.evidence),'model text keeps the code evidence tag');
  assert.ok(!r2.items.some(i=>/다시 읽기 줄이기|나눠/.test(i.title+i.how)),'old framing never reaches the page');
  assert.deepEqual(r2.items.map(i=>i.id),r.items.map(i=>i.id),'order stays by 부담');
  const r3=await h.habitCheck({snap:{datasets:[]},names:{},useModel:false,home:os.tmpdir()});assert.equal(r3.items.length,0,'no data, no items');
  fs.rmSync(dir,{recursive:true,force:true});ok('whole check: index in, rule texts, model overruled where it breaks the principles');
  console.log('RESULT '+n+' habit-check tests passed');})().catch(e=>{console.error(e);process.exitCode=1;});
