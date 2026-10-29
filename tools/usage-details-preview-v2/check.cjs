'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const core=require('./core.cjs');
const {build}=require('./builder.cjs');
const basePath=process.argv[2];
const dates=Array.from({length:14},(_,i)=>'2026-10-'+String(16+i).padStart(2,'0'));
const dataset={id:'claude_cli_local',provider:'claude',source:'claude_cli',scope:'this_device',capturedAt:'2026-10-29T01:00:00Z',latestEventAt:'2026-10-29T00:01:00Z',latestCompleteDate:'2026-10-29',semantics:{inputIncludesCache:false,outputIncludesReasoning:true,cacheReadIncludedInTotal:true,verified:'source_fields'},coverage:{status:'complete_for_selected_source',comparisonSafe:true,missingDates:[],issues:[]},days:dates.map((date,i)=>({date,tokens:i<7?10:20,input:2,output:3,cacheRead:15,cacheCreate:null,reasoning:null,records:1,coverageStatus:'observed'})),breakdowns:{project:[{date:'2026-10-29',id:'private-project',label:'Sensitive name',totals:{total:20}}],session:[],model:[],attribution:[]},activity:[]};
const S={schemaVersion:'1.0',snapshotId:'test-only',generatedAt:'2026-10-29T02:00:00Z',timezone:'Asia/Seoul',period:{from:dates[0],to:dates.at(-1)},datasets:[dataset,{...dataset,id:'aside_local',provider:'aside',source:'aside_local',days:[],breakdowns:{}}],limits:[],costs:{status:'unavailable'},outcomes:{status:'unavailable'}};
const c=core(S);
assert.equal(c.days(dataset,'7d').length,7);
assert.equal(c.bounds('7d').to,'2026-10-29');
assert.equal(c.sum(c.days(dataset,'7d')),140);
assert.equal(c.sum(c.days(S.datasets[1],'7d')),null);
assert.equal(c.sum([{tokens:0}]),0);
assert.equal(c.sum([{tokens:null}]),null);
assert.equal(c.compare(dataset,'7d').percent,100);
assert.equal(c.compare({...dataset,latestCompleteDate:'2026-10-28'},'7d').safe,false);
assert.equal(c.compare({...dataset,coverage:{comparisonSafe:false}},'7d').safe,false);
assert.equal(c.compare({...dataset,days:dataset.days.slice(1)},'7d').safe,false);
assert.equal(c.compare(dataset,'all').safe,false);
assert.equal(c.groups(dataset,'7d','project')[0].tokens,20);
const sampleBase='<style>body{font-family:Pretendard}</style><script>const logos={"claude":"data:image/png;base64,AAAA"};</script>';
const html=build(basePath?fs.readFileSync(basePath,'utf8'):sampleBase,S);
assert.equal((html.match(/<script>/g)||[]).length,1);
assert.ok(!/[\u00b7\u318d\u2022]/.test(html));
assert.ok(!html.includes('Sensitive name'));
assert.ok(!html.includes('private-project'));
assert.ok(html.includes('connect-src \'none\''));
assert.ok(!/<script[^>]+src=|<link\b/i.test(html));
const script=html.match(/<script>([\s\S]*)<\/script>/)[1];
new vm.Script(script);
// Lightweight render/event smoke tests without a browser, network or executing apps.
const nodes=new Map(),listeners={};
const node=id=>{if(!nodes.has(id))nodes.set(id,{innerHTML:'',textContent:'',hidden:false,open:false,dataset:{},setAttribute(){},showModal(){this.open=true;},close(){this.open=false;}});return nodes.get(id);};
const document={documentElement:{lang:'ko',dataset:{}},title:'',querySelector:node,querySelectorAll(){return[];},addEventListener(name,fn){listeners[name]=fn;}};
vm.runInNewContext(script,{document,Intl,Date,Map,Set,console});
assert.ok(node('#view').innerHTML.includes('20'));
assert.ok(node('#providers').innerHTML.includes('Aside'));
assert.ok(!node('#view').textContent.includes('표시할 수 없어요'));
function click(dataset={},id=''){listeners.click({target:{closest(){return {dataset,id};}}});}
click({lang:'en'});
assert.equal(document.documentElement.lang,'en');
assert.ok(node('#view').innerHTML.includes('Latest recorded day'));
click({view:'insights'});assert.ok(node('#view').innerHTML.includes('Unknown attribution')||node('#view').innerHTML.includes('Unknown attribution is not guessed'));
assert.ok(node('#view').innerHTML.includes('140'));
click({view:'ai'});assert.ok(node('#view').innerHTML.includes('cloud AI'));
click({view:'sources'});assert.ok(node('#view').innerHTML.includes('Latest complete date'));
click({provider:'aside'});click({view:'overview'});assert.ok(node('#view').innerHTML.includes('Unavailable'));
click({},'coverage');assert.equal(node('#detail-dialog').open,true);
click({},'dialog-close');assert.equal(node('#detail-dialog').open,false);
// --- v2 fixtures: 10 limits, recovered Aside, top10 folding, per-dataset all-period start ---
{
  const dayList=(from,n,v)=>Array.from({length:n},(_,i)=>({date:new Date(Date.parse(from+'T00:00:00Z')+i*86400000).toISOString().slice(0,10),tokens:v,input:1,output:1,cacheRead:v-2,cacheCreate:null,reasoning:null,records:1,coverageStatus:'observed'}));
  const codexDays=dayList('2026-02-03',269,5);          // 2026-02-03 .. 2026-10-29
  const localDays=dayList('2026-09-30',30,7);           // last 30 days only
  const mk=(id,provider,source,days,extra={})=>({id,provider,source,scope:'this_device',capturedAt:'2026-10-29T01:00:00Z',latestCompleteDate:'2026-10-29',semantics:{verified:'source_fields'},coverage:{status:'partial',comparisonSafe:false,missingDates:[],issues:[]},days,breakdowns:{project:[],session:[],model:[],attribution:[]},activity:[],...extra});
  const sessions=Array.from({length:25},(_,i)=>({date:'2026-10-29',id:'s'+i,label:'name'+i,totals:{total:i+1}}));
  const codex=mk('codex_server','codex','codex_server',codexDays,{scope:'account'});
  const local=mk('codex_local','codex','codex_cli',localDays,{breakdowns:{project:[],session:sessions,model:[],attribution:[]}});
  const rec=mk('aside_unattributed','aside','aside_turns',dayList('2026-10-20',10,9),{coverage:{status:'partial',comparisonSafe:false,missingDates:[],issues:[{code:'missing_aside_session_files'},'unmetered_records'],unmeteredRecords:3},activity:[{date:'2026-10-29',hour:3,tokens:9,records:1}]});
  const empty=mk('claude_empty','claude','claude_cli',[]);
  const providers=['codex','claude','grok','antigravity','aside'];
  const limits=Array.from({length:10},(_,i)=>({provider:providers[i%5],window:'5h',unit:'percent',status:'observed',remainingPercent:50+i,capturedAt:'2026-10-29T01:00:00Z',resetAt:null}));
  const V={schemaVersion:'1.0',snapshotId:'t2',generatedAt:'2026-10-29T02:00:00Z',timezone:'Asia/Seoul',period:{from:'2026-02-03',to:'2026-10-29'},datasets:[codex,local,rec,empty],limits,costs:{status:'unavailable'},outcomes:{status:'unavailable'}};
  const k=core(V);
  assert.equal(k.bounds('all',codex).from,'2026-02-03');
  assert.equal(k.bounds('all',local).from,'2026-09-30');
  assert.equal(k.bounds('all',empty).from,'2026-02-03');           // no data: global fallback
  assert.equal(k.bounds('7d',local).from,'2026-10-23');
  assert.equal(k.bounds('30d',codex).from,'2026-09-30');
  assert.equal(k.days(local,'all').length,30);
  assert.equal(k.days(codex,'all').length,269);
  assert.equal(k.days(empty,'all').length,269);
  assert.equal(k.sum(k.days(local,'all')),210);
  assert.equal(k.groups(local,'all','session').length,25);
  assert.equal(k.sum(k.groups(local,'all','session')),325);
  const h=build(sampleBase,V);
  assert.ok(!/[\u00b7\u318d\u2022]/.test(h));
  const sc=h.match(/<script>([\s\S]*)<\/script>/)[1];
  const nd=new Map(),ls={};
  const nn=id=>{if(!nd.has(id))nd.set(id,{innerHTML:'',textContent:'',hidden:false,open:false,dataset:{},setAttribute(){},showModal(){this.open=true;},close(){this.open=false;}});return nd.get(id);};
  const doc={documentElement:{lang:'ko',dataset:{}},title:'',querySelector:nn,querySelectorAll(){return[];},addEventListener(n,f){ls[n]=f;}};
  vm.runInNewContext(sc,{document:doc,Intl,Date,Map,Set,console});
  const clk=(ds={},id='')=>ls.click({target:{closest(){return {dataset:ds,id};}}});
  const view=()=>nn('#view').innerHTML;
  // 1) limits: only the selected provider (2 of 10)
  assert.equal((view().match(/class="quota-row"/g)||[]).length,2);
  clk({provider:'claude'});assert.equal((view().match(/class="quota-row"/g)||[]).length,2);
  // 5) token chips: compact text with exact title; short rule + details button
  clk({provider:'codex'});
  assert.ok(/<span title="[^"]*: [\d,]+">[^<]*<strong class="num">[^<]+<\/strong>/.test(view()));
  assert.ok(view().includes('data-details='));
  assert.ok(!/집계 규칙은 가정|Documented counting/.test(view()));
  // 4) all period: server dataset starts 2026-02-03, local starts 2026-09-30 (caption)
  clk({period:'all'});assert.ok(view().includes('2026'));assert.ok(/2월 3일|Feb 3/.test(view()));
  clk({lang:'en'});assert.ok(/Feb 3, 2026/.test(view()));
  clk({view:'records'});assert.equal((view().match(/<tr>/g)||[]).length,270);
  // 3) top 10 + rest + collapsible full list, totals preserved
  clk({view:'overview'});
  doc.documentElement.lang='en';
  ls.change({target:{id:'dataset',value:'1'}});
  clk({view:'insights'});ls.change({target:{id:'dimension',value:'session'}});
  clk({period:'all'});
  const v=view();
  assert.ok(v.includes('Other 15'));assert.ok(v.includes('View all 25 items'));
  assert.ok(v.includes('<details'));
  assert.ok(v.includes('Breakdown does not match'));
  assert.ok(v.includes('Other 15</td><td class="num">120</td>'));   // 1..15 sum = 120
  
  // 2) recovered Aside: label, no hourly table, modal explains each code in both languages
  clk({provider:'aside'});
  assert.ok(nn('#controls').innerHTML.includes('Recovered Aside summaries'));
  assert.ok(view().includes('Recovered Aside summaries')||nn('#controls').innerHTML.includes('Recovered'));
  clk({view:'insights'});assert.ok(/hourly analysis is not provided/.test(view()));assert.ok(!/<th>Hour<\/th>/.test(view()));
  clk({},'coverage');
  let body=nn('#dialog-body').innerHTML;
  for(const s of ['model was not recorded','turn end date','overlap with other sources','session files were not found','no token counts'])assert.ok(body.toLowerCase().includes(s),s);
  assert.ok(!/model_attribution_unavailable|turn_end_date_not_event_time|cross_source_overlap_unverified|missing_aside_session_files|unmetered_records/.test(body));
  clk({lang:'ko'});body=nn('#dialog-body').innerHTML;
  for(const s of ['당시 모델은 기록에 없어','턴 종료일 우선','다른 출처와 겹치는지','Aside 세션 파일을 찾지 못','토큰 수치가 없는'])assert.ok(body.includes(s),s);
  assert.ok(nn('#controls').innerHTML.includes('Aside 복구 요약'));
  assert.ok(!/[\u00b7\u318d\u2022]/.test(body));
}require('./check-v2.cjs')({assert,fs,vm,core,build,sampleBase}).then(()=>console.log('PASS v2: columns, empty period, hidden/AI, copy, keyboard, focus restore, quota, sources, dialog, insights, numbers, KO/EN, offline, real snapshot.')).catch(e=>{console.error(e);process.exitCode=1;});console.log('PASS: core semantics, safe comparisons, masking, one-script offline HTML, KO/EN render, dynamic Aside provider, all views and dialog.');
