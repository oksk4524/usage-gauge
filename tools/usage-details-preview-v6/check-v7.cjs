'use strict';
// v7 checks (2026-10-30, evidence pass): the AI habit check shows an evidence tag per item and one compact reference
// table (source, 한도를 쓴 양, 캐시 적중, 모델별로 한도를 쓴 양) with each note once; "지금 할 일", "이번 주 많이 쓴 곳" and
// "지난주와 비교" count 한도를 쓴 양 and carry no "다시 읽은 양 …배" judgment. Fake DOM: markup only.
module.exports=async function({assert,fs,vm,build,sampleBase}){
  const day=(i)=>new Date(Date.parse('2026-10-16T00:00:00Z')+i*864e5).toISOString().slice(0,10);
  const tot=(cr,cc,inp,out)=>({input:inp,output:out,cacheRead:cr,cacheCreate:cc,reasoning:0,total:inp+out+cr+cc,records:10});
  const days=Array.from({length:14},(_,i)=>({date:day(i),tokens:0,...tot(1e7,1e5,100,1e4),coverageStatus:'observed'}));days.forEach(d=>d.tokens=d.total);
  const model=days.map(d=>({date:d.date,id:'claude-opus-5-5',label:'claude-opus-5-5',totals:tot(1e7,1e5,100,1e4)}));
  // a project with a high re-read multiple: ranked by 한도를 쓴 양, never judged by the multiple
  const project=days.map(d=>({date:d.date,id:'project 1111111111111111',label:'project 1111111111111111',totals:tot(1e7,1e5,100,1e4)}));
  const now=Date.now(),iso=ms=>new Date(ms).toISOString();
  const recentSessions=[{session:'aaaaaaaaaaaaaaaa',lastAt:iso(now-2*3600e3),lastContext:600000,project:'unknown'},{session:'bbbbbbbbbbbbbbbb',lastAt:iso(now-20*60e3),lastContext:700000,project:'unknown'}];
  const ds={id:'claude_aside_local',provider:'claude',source:'aside_messages',scope:'this_device',capturedAt:'2026-10-29T01:00:00Z',latestCompleteDate:day(13),
    semantics:{totalRule:'input_plus_output_plus_cache_read',inputIncludesCache:false,outputIncludesReasoning:true,cacheReadIncludedInTotal:true,verified:'source_fields'},coverage:{status:'complete_for_selected_source',comparisonSafe:true,missingDates:[],issues:[]},
    days,breakdowns:{project,session:[],model,attribution:[]},activity:[],efficiency:{status:'observed',requests:500,recentSessions}};
  const habit={at:'2026-10-30T13:40:57Z',model:null,dropped:[],basis:'캐시 적중은 높을수록 좋아요. 한도를 쓴 양은 요금 기준 추정으로 셌어요.',
    items:[{id:'cold-claude_aside_local',title:'Aside Claude는 60분 안에 이어 쓰면 한도를 최대 7% 아껴요',why:'쉬는 걸 다 피할 수는 없어서 7%는 최대치예요.',how:'60분 안에 이어서 쓰면 다시 읽기(캐시)로 끝나요. 오래 쉴 거면 정리해 두고 새 대화로 시작해요.',evidence:'추정',by:'rule'},
      {id:'x',title:'기록 항목',why:'w',how:'h',evidence:'기록으로 확인함',by:'rule'},{id:'y',title:'잘못된 태그',why:'w',how:'h',evidence:'<b>',by:'rule'}],
    table:[{source:'Aside Claude',used:'7.3억',hit:'98%',models:'Opus 5.5 93%, Sonnet 5.5 7%'},{source:'Aside Codex',used:'2.6억',hit:'96%',models:'GPT-6 Astra 66%'}],
    notes:['GPT-6 Astra는 AI가 쓴 답의 공개 요금이 없어 4배로 셌어요.','실험해 볼 거리: 계산이 나와요.'],weights:{claude_aside_local:{write:2,life:60}}};
  const S={schemaVersion:'1.0',snapshotId:'v7',generatedAt:'2026-10-30T02:00:00Z',timezone:'Asia/Seoul',period:{from:day(0),to:day(13)},datasets:[ds],limits:[],costs:{status:'unavailable'},outcomes:{status:'unavailable'},localHabit:habit,localNames:{aaaaaaaaaaaaaaaa:'긴 대화'}};
  const html=build(sampleBase,S),sc=html.match(/<script>([\s\S]*)<\/script>/)[1];
  const nd=new Map(),nn=id=>{if(!nd.has(id))nd.set(id,{innerHTML:'',textContent:'',hidden:false,open:false,dataset:{},className:'',clientWidth:700,setAttribute(){},focus(){},showModal(){},close(){}});return nd.get(id);};
  const doc={documentElement:{lang:'ko',dataset:{},clientWidth:1200},title:'',activeElement:null,querySelector:nn,querySelectorAll(){return[];},addEventListener(){}};
  vm.runInNewContext(sc,{document:doc,Intl,Date,Map,Set,console});const v=nn("#today").innerHTML;if(process.env.V7DUMP)console.log(v);
  const block=(head)=>{const i=v.indexOf('>'+head);assert.ok(i>=0,'section shown: '+head);const j=v.indexOf('today-head',i+10);return v.slice(i,j<0?undefined:j);};
  // 1) habit check: evidence tags, compact table, notes once, one shared line
  const hb=block('AI 습관 진단');
  assert.ok(hb.includes('<span class="habit-tag est">추정</span>')&&hb.includes('<span class="habit-tag">기록으로 확인함</span>'),'evidence tag per item');
  assert.ok(!hb.includes('&lt;b&gt;')&&(hb.match(/habit-tag/g)||[]).length===2,'unknown tags dropped');
  assert.ok(/<table class="habit-table"><thead><tr><th>출처<\/th><th class="num">한도를 쓴 양<\/th><th class="num">캐시 적중<\/th><th>모델별로 한도를 쓴 양<\/th><\/tr><\/thead>/.test(hb),'reference table columns');
  assert.equal((hb.match(/<tr>/g)||[]).length,3,'header plus one row per source');
  assert.ok(hb.includes('<td>Aside Claude</td><td class="num">7.3억</td><td class="num">98%</td>'),'row cells');
  assert.equal((hb.match(/공개 요금이 없어/g)||[]).length,1,'unknown-price note once');assert.equal((hb.match(/habit-basis/g)||[]).length,1,'shared line once');
  assert.ok(!/적중률이 높을수록 좋아요[\s\S]*적중률이 높을수록 좋아요/.test(hb)&&!hb.includes('today-rows habit-info'),'no per-source cards repeating the explanation');
  // 2) 지금 할 일: only the conversation past the cache lifetime, in cache-loss words with 한도를 쓴 양 (600000 x 2)
  const now1=block('지금 할 일');
  assert.ok(now1.includes('&quot;긴 대화&quot;')&&!now1.includes('70만'),'listed only after the cache lifetime (2 hours ago, not 20 minutes ago)');
  assert.ok(now1.includes('60분이 지나 캐시가 사라졌을 거라')&&now1.includes('한도를 쓴 양은 120만이에요'),'cache-loss framing with 한도를 쓴 양');
  assert.ok(!/처음부터 다시 읽어요|압축 기준 낮추기/.test(v),'old re-read row and the compaction setting row are gone');
  // 3) weekly and last-week: 한도를 쓴 양, no "다시 읽은 양 …배"
  const wk=block('이번 주 많이 쓴 곳');
  assert.ok(wk.includes('한도를 쓴 양, 지난 7일')&&!/다시 읽은 양|새로 처리한|배</.test(wk),'week list counts 한도를 쓴 양 without the multiple');
  const perDay=1e7*0.1+1e5*2+100+1e4*5;   // 한도를 쓴 양 per day with the habit check's 2x Claude writes
  assert.ok(wk.includes('>'+Math.round(perDay*7/1e4)+'만<'),'week value = weighted sum ('+Math.round(perDay*7/1e4)+'만)');
  const tr=block('지난주와 비교');assert.ok(tr.includes('한도를 쓴 양, 지난 7일과 그 전 7일')&&tr.includes('>'+Math.round(perDay*7/1e4)+'만<'),'trend in 한도를 쓴 양');
  assert.ok(!/최근 30일 습관|다시 읽은 양 포함/.test(v),'old habit line and re-read multiple gone');
  assert.ok(!/[\u00b7\u2022\u2219]/.test(v),'no middle dots');
  console.log('PASS v7: evidence tags, compact reference table, 지금 할 일 and weekly sections in 한도를 쓴 양.');
};
