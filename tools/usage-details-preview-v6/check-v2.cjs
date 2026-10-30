'use strict';
// v2 regression tests. Loaded by check.cjs; synthetic fixtures plus the real snapshot when present.
module.exports = async function({assert, fs, vm, core, build, sampleBase}) {
  const dayL=(from,n,f)=>Array.from({length:n},(_,i)=>{const date=new Date(Date.parse(from+'T00:00:00Z')+i*86400000).toISOString().slice(0,10);return {date,...f(i)};});
  const obs=v=>({tokens:v,input:v-8,output:3,cacheRead:4,cacheCreate:1,reasoning:null,records:1,coverageStatus:'observed'});
  const mkD=(id,provider,source,days,extra={})=>({id,provider,source,scope:'this_device',capturedAt:'2026-10-29T01:00:00Z',latestCompleteDate:'2026-10-29',semantics:{totalRule:'input_plus_output_plus_cache_read_plus_cache_create',inputIncludesCache:false,outputIncludesReasoning:true,cacheReadIncludedInTotal:true,verified:'source_fields'},coverage:{status:'partial',comparisonSafe:false,missingDates:[],issues:[]},days,breakdowns:{project:[],session:[],model:[],attribution:[]},activity:[],...extra});
  const env=(S0,{width,navigator:nav}={})=>{
    const h=build(sampleBase,S0),sc=h.match(/<script>([\s\S]*)<\/script>/)[1],nd=new Map(),ls={};
    const nn=id=>{if(!nd.has(id))nd.set(id,{innerHTML:'',textContent:'',hidden:false,open:false,dataset:{},focused:0,setAttribute(){},focus(){this.focused++;},showModal(){this.open=true;},close(){this.open=false;}});return nd.get(id);};
    if(width)nn('#chart-host').clientWidth=width;
    const doc={documentElement:{lang:'ko',dataset:{}},title:'',querySelector:nn,querySelectorAll(){return[];},addEventListener(n,f){ls[n]=f;}};
    vm.runInNewContext(sc,{document:doc,Intl,Date,Map,Set,console,navigator:nav});
    const clk=(ds={},id='')=>ls.click({target:{closest(){return {dataset:ds,id};}}});
    return {h,doc,ls,nn,clk,view:()=>nn('#view').innerHTML};
  };
  const tick=()=>new Promise(r=>setTimeout(r,5));
  // --- core helpers
  const days30=dayL('2026-10-01',29,i=>obs(10+i));
  const base=mkD('d1','claude','claude_cli',days30,{coverage:{status:'complete_for_selected_source',comparisonSafe:true,missingDates:['2026-10-03','2026-10-04','2026-10-05','2026-10-09','2026-10-20','2026-10-21','2026-10-22','2026-10-23','2026-10-24'],issues:[]}});
  const stale=mkD('d2','grok','grok_usage_json',dayL('2026-09-01',20,()=>obs(5)));   // last record 2026-09-20
  const S2={schemaVersion:'1.0',snapshotId:'v2',generatedAt:'2026-10-29T02:00:00Z',timezone:'Asia/Seoul',period:{from:'2026-09-01',to:'2026-10-29'},datasets:[base,stale,mkD('d3','claude','aside_messages',[])],limits:[{provider:'claude',window:'5h',unit:'percent',status:'observed',remainingPercent:96,capturedAt:'2026-10-29T01:00:00Z'},{provider:'claude',window:'7d',unit:'percent',status:'observed',remainingPercent:3,capturedAt:'2026-10-29T01:00:00Z',resetAt:'2026-11-02T03:00:00Z'},{provider:'grok',window:'7d',unit:'percent',status:'observed',remainingPercent:0,capturedAt:'2026-10-29T01:00:00Z'},{provider:'grok',window:'7d',model:'other-bucket',unit:'percent',status:'observed',remainingPercent:100,capturedAt:'2026-10-29T01:00:00Z'}],costs:{status:'unavailable'},outcomes:{status:'unavailable'}};
  const K=core(S2);
  assert.equal(K.lastDate(stale),'2026-09-20');
  assert.equal(K.lastDate(S2.datasets[2]),null);
  assert.deepEqual(K.bounds('last30',stale),{from:'2026-08-22',to:'2026-09-20'});
  assert.equal(K.compare(stale,'last30').safe,false);
  assert.equal(K.sum(K.days(stale,'7d')),null);                 // null stays null, never 0
  assert.equal(K.sum(K.days(stale,'last30')),100);
  assert.deepEqual(K.ranges(['2026-10-05','2026-10-03','2026-10-04','2026-10-09']),[{from:'2026-10-03',to:'2026-10-05',count:3},{from:'2026-10-09',to:'2026-10-09',count:1}]);
  // --- built HTML: offline + hidden bug fix
  const E=env(S2);
  assert.ok(E.h.includes('[hidden]{display:none!important}'));
  assert.ok(!/\b(?:src|href)="https?:|@import|url\(\s*["']?https?:/i.test(E.h));
  assert.ok(E.h.includes("connect-src 'none'"));
  assert.ok(E.h.includes('.chart g:focus-visible .bar')&&E.h.includes('.chart g:focus-visible text'),'keyboard focus highlights the actual bar or missing/zero label, not an extra column');
  // v3 structure regressions: narrow chart, flow header, navigation and quota access.
  const N=env(S2,{width:239});
  assert.ok(N.nn('#chart-host').innerHTML.includes('width="239"'));
  assert.ok(!N.nn('#chart-host').innerHTML.includes('scroll-hint'));
  assert.ok(N.h.includes('class="app-header"')&&N.h.includes('id="view-select"'));
  assert.equal((N.h.match(/id="theme"/g)||[]).length,1);
  assert.ok(N.h.includes('id="providers" role="group"'));
  assert.ok(N.nn('#controls').innerHTML.includes('id="dataset" aria-label="출처"'));
  N.ls.change({target:{id:'view-select',value:'records'}});
  assert.ok(N.view().includes('일별 토큰 기록'));
  assert.ok(N.nn('#view-select').innerHTML.includes('value="records" selected'));
  N.ls.change({target:{id:'view-select',value:'overview'}});
  assert.ok(!N.view().includes('quota-alert')&&!N.view().includes('data-quota'),'v5: no duplicate low-quota banner');
  assert.ok(N.view().includes('quota-value num warning')&&N.view().includes('남은 한도')&&N.view().includes('저장된 값'));
  N.clk({provider:'grok'});N.clk({period:'last30'});
  assert.ok(N.nn('#controls').className.includes('has-last-range'));
  // --- columns: cache creation + reasoning always present, nulls are dashes, numbers right aligned, status left
  E.clk({view:'records'});
  let v=E.view();
  for(const s of ['캐시 생성','추론','출력에 포함, 다시 더하지 않음','전체 토큰 = 입력 + 출력 + 캐시 읽기 + 캐시 생성','role="region"'])assert.ok(v.includes(s),s);
  assert.ok(v.includes('records-unsupported')&&/<dt>추론<\/dt><dd><span class="na"/.test(v),'unsupported reasoning remains explicitly unknown in disclosure');
  assert.ok(/<td class="num">\d+<\/td>/.test(v));
  assert.ok(/<td class="status-cell">/.test(v)&&/<td class="date">/.test(v));
  assert.equal((v.match(/<th class="num">/g)||[]).length,5,'total and four supported numeric fields stay in the primary table');
  E.clk({lang:'en'});v=E.view();
  assert.ok(v.includes('Cache creation')&&v.includes('Reasoning')&&v.includes('In output, not added again'));
  assert.ok(v.includes('Total tokens = input + output + cache read + cache creation'));
  E.clk({lang:'ko'});
  const G=env({...S2,datasets:[mkD('g','grok','grok_usage_json',days30,{semantics:{totalRule:'input_plus_output',inputIncludesCache:true,outputIncludesReasoning:true,verified:'source_fields'}})]});
  G.clk({view:'records'});assert.ok(G.view().includes('입력에 포함')&&G.view().includes('전체 토큰 = 입력 + 출력'));
  assert.ok(v.includes('<th>Date</th><th class="num">Total tokens</th>'),'Total follows the date on narrow screens');
  // --- empty period: no fake axis, no bar hint, last-record/all actions, no fake refresh button
  E.clk({provider:'grok'});E.clk({view:'overview'});v=E.view();
  assert.ok(v.includes('data-period="last30"')&&v.includes('data-period="all"'));
  assert.ok(!v.includes('chart-readout')&&!v.includes('class="grid"')&&!v.includes('막대를 선택'));
  assert.ok(v.includes('사용량이 0이라는 뜻은 아니에요')&&!/재수집|refresh/i.test(v));
  E.clk({period:'last30'});v=E.view();
  assert.ok(v.includes('chart-readout')&&v.includes('class="grid"')&&!/data-period="last30"/.test(v));
  assert.ok(E.nn('#controls').innerHTML.includes('마지막 기록일 기준 30일'));
  E.clk({provider:'claude'});assert.ok(!E.nn('#controls').innerHTML.includes('마지막 기록일 기준 30일'));
  // --- chart sized to the real card width; 7 days fit; 30 days scroll hint; legend; monthly notice
  const W=env(S2,{width:1000});W.clk({provider:'claude'});
  assert.ok(W.nn('#chart-host').innerHTML.includes('width="1000"')&&W.nn('#chart-host').innerHTML.includes('viewBox="0 0 1000 '));
  const M=env(S2,{width:340});M.clk({provider:'claude'});
  assert.ok(M.nn('#chart-host').innerHTML.includes('width="340"')&&!M.nn('#chart-host').innerHTML.includes('scroll-hint'));
  M.clk({period:'30d'});
  assert.ok(M.view().includes('chart-pager')&&!M.view().includes('scroll-hint'));
  assert.ok(M.view().includes('viewBox="0 0 340 '),'PC chart pages instead of extending beyond its card');
  assert.ok(!M.view().includes('class="legend"')&&M.view().includes('class="chart-title"'),'chart is labelled directly instead of a coded legend');
  // --- keyboard: roving tabindex + arrows
  assert.ok(/<g tabindex="0"[^>]*data-i="\d+"/.test(M.nn('#chart-host').innerHTML));
  {const gs=[0,1,2].map(i=>({dataset:{readout:'r'+i},attrs:{},setAttribute(k,x){this.attrs[k]=x;},focus(){this.f=1;}}));M.nn('#chart-scroll').querySelectorAll=()=>gs;let pd=0;
   M.ls.keydown({target:gs[1],key:'ArrowRight',preventDefault(){pd++;}});assert.equal(gs[2].f,1);assert.equal(gs[2].attrs.tabindex,'0');assert.equal(gs[1].attrs.tabindex,'-1');
   M.ls.keydown({target:gs[2],key:'Home',preventDefault(){pd++;}});assert.equal(gs[0].f,1);assert.equal(M.nn('#chart-readout').textContent,'r0');assert.equal(pd,2);}
  // --- focus restoration after render replaces controls/nav
  {const d2=env(S2);d2.doc.activeElement={id:'dataset',dataset:{}};d2.ls.change({target:{id:'dataset',value:'0'}});assert.ok(d2.nn('#dataset').focused>=1);
   d2.doc.activeElement={dataset:{period:'30d'}};d2.clk({period:'30d'});assert.ok(d2.nn('[data-period="30d"]').focused>=1);
   d2.doc.activeElement={dataset:{view:'insights'}};d2.clk({view:'insights'});assert.ok(d2.nn('[data-view="insights"]').focused>=1);}
  // --- low remaining values: separate state, no bucket merge, checked time kept
  E.clk({provider:'claude'});E.clk({view:'overview'});v=E.view();
  assert.ok(v.includes('quota-value num warning')&&!v.includes('5% 이하')&&v.includes('class="track warning"'));
  assert.ok(!v.includes('잔여 한도가 적어요')&&!v.includes('실시간 상태나 예측은 아니에요')&&!v.includes('확인:'),'v5: caption prose and exact times are not on the first screen');
  E.clk({usage:'1'});{const db=E.nn('#dialog-body').innerHTML;assert.ok(db.includes('실시간 상태나 예측이 아니고')&&db.includes('5% 이하로 남으면 강조해서 보여 줘요')&&/확인: [^<]*경과/.test(db)&&/에 다시 차요|다시 차는 시각을 아직 몰라요/.test(db)&&db.includes('남은 한도'),'v5: exact checked/reset in details');}E.clk({},'dialog-close');
  assert.equal((v.match(/class="quota-row"/g)||[]).length,2);
  assert.ok(v.includes('남은 한도')&&/저장된 값 \/ [^<]*경과/.test(v));
  assert.ok(!v.includes('누락 날짜')&&!v.includes('계정 한도와 크레딧'));
  E.clk({provider:'grok'});v=E.view();
  assert.equal((v.match(/class="quota-row"/g)||[]).length,2);assert.ok(v.includes('other-bucket')&&/quota-value num warning">0%/.test(v));
  assert.equal((v.match(/quota-value num warning/g)||[]).length,1);
  // --- overview source table replaced by summary; full list lives in sources
  E.clk({provider:'claude'});v=E.view();
  assert.ok(!v.includes('source-summary')&&!v.includes('data-view="sources"')&&!v.includes('data-details='),'v5: no source status block on first screen');
  E.clk({usage:'1'});assert.ok(E.nn('#dialog-body').innerHTML.includes('data-view="sources"')&&E.nn('#dialog-body').innerHTML.includes('출처 3개'));E.clk({},'dialog-close');
  E.clk({view:'sources'});v=E.view();
  assert.equal((v.match(/<td class="date">/g)||[]).length,3);
  assert.ok(v.includes('전체 출처 목록 3개')&&v.includes('기록의 기준 시각')&&v.includes('기록 파일을 만든 시각'));
  assert.equal(E.nn('#freshness').hidden,true);assert.equal(E.nn('#breadcrumb').hidden,true);
  // --- dialog: reason count first, gaps grouped into ranges, label rename
  E.clk({},'scope-button');let body=E.nn('#dialog-body').innerHTML;
  assert.ok(body.indexOf('참고 사항')<body.indexOf('<dl>'));
  assert.ok(body.includes('기록 없는 날짜')&&!body.includes('누락 날짜'));
  assert.ok(body.includes('9일, 연속 구간 3개'));
  const many=mkD('m','claude','claude_cli',days30,{coverage:{status:'partial',comparisonSafe:false,missingDates:['2026-10-01','2026-10-03','2026-10-05','2026-10-07','2026-10-09'],issues:['aside_session_files_missing']}});
  const R=env({...S2,datasets:[many,mkD('aside_unattributed','aside','aside_turns',days30)],limits:[]});
  R.clk({},'scope-button');body=R.nn('#dialog-body').innerHTML;
  assert.ok(body.includes('전체 5개 구간 보기')&&body.includes('<details class="fold">'));
  assert.ok(body.includes('data-recovered="aside_unattributed"'));
  R.clk({recovered:'aside_unattributed'});assert.equal(R.nn('#detail-dialog').open,false);
  assert.ok(R.nn('#controls').innerHTML.includes('Aside 복구 요약'));
  R.clk({usage:'1'});assert.ok(R.nn('#dialog-body').innerHTML.includes('턴 종료일 우선'),'v5: record-date basis kept in details');R.clk({},'dialog-close');
  // --- insights: peak + breakdown first, hourly table folded, notices folded but kept
  const withAct=mkD('a','claude','claude_cli',days30,{activity:[{date:'2026-10-28',hour:3,tokens:9,records:1},{date:'2026-10-28',hour:14,tokens:50,records:2}],breakdowns:{project:[],session:[],attribution:[],model:[{date:'2026-10-28',id:'m',label:'claude-sonnet-x',totals:{total:5}}]}});
  const I=env({...S2,datasets:[withAct]});I.clk({view:'insights'});v=I.view();
  assert.ok(v.indexOf('전체 토큰이 가장 많았던 날')<v.indexOf('사용량 분류'));
  assert.ok(v.indexOf('사용량 분류')<v.indexOf('시간대별 토큰 이벤트'));
  assert.ok(/<option value="model" selected>/.test(v));
  assert.ok(v.includes('전체 토큰이 가장 많았던 시간대')&&/<details class="fold"><summary>시간대별 표 보기/.test(v));
  assert.ok(v.includes('비교할 수 없어요')&&v.includes('<summary>이유 보기</summary>'));
  assert.ok(v.includes('<summary>추정하지 않는 정보</summary>')&&v.includes('성과와 생산성'));
  assert.ok(v.includes('근무 시간이나 실제 활동 시간이 아니에요'));
  // --- AI view: CLI vs MCP, hidden controls, copy success and failure messages, no clipboard permission request
  let copied='';
  const A1=env(S2,{navigator:{clipboard:{writeText:async x=>{copied=x;}}}});A1.clk({view:'ai'});v=A1.view();
  assert.equal(A1.nn('#providers').hidden,true);assert.equal(A1.nn('#controls').hidden,true);assert.equal(A1.nn('#scope-button').hidden,true);
  assert.ok(v.indexOf('날짜와 사용량이 해당 서비스')>=0 && v.indexOf('날짜와 사용량이 해당 서비스')<v.indexOf('id="cmd-cli"'),'Sharing notice precedes commands');
  assert.ok(v.includes('id="cmd-cli"')&&v.includes('id="cmd-mcp"')&&v.includes('data-copy="cli"')&&v.includes('data-copy="mcp"'));
  assert.ok(v.includes('UsageInsights.exe --mcp --snapshot')&&v.includes('--snapshot $file --period 7d --json')&&!/usage-gauge\.exe/.test(v));
  A1.clk({copy:'mcp'});await tick();assert.ok(copied.startsWith('.\\UsageInsights.exe --mcp'));assert.equal(A1.nn('#copy-status').textContent,'명령을 복사했어요.');
  A1.clk({copy:'cli'});await tick();assert.ok(copied.includes('& $exe limits --snapshot $file --json'));
  const A2=env(S2,{navigator:{clipboard:{writeText:async()=>{throw new Error('denied');}}}});A2.clk({view:'ai'});A2.clk({copy:'cli'});await tick();
  assert.ok(A2.nn('#copy-status').textContent.includes('복사하지 못했어요'));
  const A3=env(S2);A3.clk({view:'ai'});A3.clk({copy:'cli'});await tick();assert.ok(A3.nn('#copy-status').textContent.includes('복사하지 못했어요'));
  A1.clk({lang:'en'});assert.ok(A1.view().includes('MCP: connect from an AI app')&&A1.view().includes('cloud AI'));
  // --- numbers: exact total visible and copyable; compact has at most one decimal
  E.clk({provider:'claude'});E.clk({view:'overview'});E.clk({lang:'ko'});v=E.view();
  assert.ok(!v.includes('정확한 합계')&&!v.includes('data-copy="total"')&&!v.includes('기록일 평균'),'v5: exact/average lines are not always visible');
  E.clk({usage:'1'});{const db=E.nn('#dialog-body').innerHTML;assert.ok(/<dt>정확한 합계<\/dt><dd><strong class="num">[\d,]+<\/strong> <button class="text-button" data-copy="total" data-text="\d+"/.test(db));assert.ok(db.includes('토큰 구성')&&db.includes('<dt>기록일 평균</dt>')&&db.includes('<dt>최신 기록일</dt>')&&db.includes('합계에 포함'));}E.clk({},'dialog-close');
  const big=env({...S2,datasets:[mkD('b','claude','claude_cli',dayL('2026-10-23',7,()=>obs(667531150)))]});
  assert.ok(!/\d+\.\d{2,}(억|만)/.test(big.view())&&!/\d+\.\d{2,}[KMBT]/.test(big.view()));
  assert.ok(big.view().includes('46.7억'));
  big.clk({lang:'en'});assert.ok(/\b4\.7B\b/.test(big.view()));
  // --- KO/EN parity of renamed labels
  E.clk({view:'sources'});E.clk({lang:'en'});assert.ok(E.view().includes('Dates without records')&&!E.view().includes('Missing dates'));
  E.clk({view:'overview'});assert.ok(E.view().includes('Remaining quota')&&!E.view().includes('Account limits and credits'));
  // --- real snapshot (optional)
  const RP=process.env.USAGE_SNAPSHOT||'';
  if(fs.existsSync(RP)){
    const real=JSON.parse(fs.readFileSync(RP,'utf8')),Rc=core(real),X=env(real);
    for(const ds of real.datasets){
      X.clk({provider:ds.provider});X.ls.change({target:{id:'dataset',value:String(real.datasets.indexOf(ds))}});
      for(const vw of ['overview','records','insights','sources']){X.clk({view:vw});assert.ok(!X.view().includes('표시할 수 없어요'),ds.id+' '+vw);}
      for(const pr of ['7d','30d','all','last30']){X.clk({view:'records'});X.clk({period:pr});assert.equal((X.view().match(/<tr>/g)||[]).length,Rc.days(ds,pr).length+1,ds.id+' '+pr);}
      X.clk({view:'overview'});X.clk({period:'30d'});
      const tot=Rc.sum(Rc.days(ds,'30d'));
      X.clk({usage:'1'});const xb=X.nn('#dialog-body').innerHTML;X.clk({},'dialog-close');
      if(tot!==null)assert.ok(xb.includes('<dt>정확한 합계</dt><dd><strong class="num">'+tot.toLocaleString('ko-KR')),ds.id+' exact total (details)');else assert.ok(!xb.includes('<dt>정확한 합계</dt>'));
      assert.ok(!X.view().includes('정확한 합계'),ds.id+' no exact-total line on first screen');
    }
    X.clk({provider:'antigravity'});X.clk({view:'overview'});
    assert.equal((X.view().match(/class="quota-row"/g)||[]).length,real.limits.filter(l=>l.provider==='antigravity').length);
    // low-quota warning follows the saved data (it changes with the signed-in account), not a fixed expectation
    const lowClaude=real.limits.some(l=>l.provider==='claude'&&l.status==='observed'&&l.remainingPercent<=5);
    const quotaHtml=()=>(X.view().match(/<aside class="panel quota-panel"[\s\S]*?<\/aside>/)||[''])[0];
    X.clk({provider:'claude'});assert.equal(quotaHtml().includes('quota-value num warning'),lowClaude);
    for(const l of real.limits.filter(l=>l.provider==='claude'&&l.accountLabel))assert.ok(X.view().includes(l.accountLabel),'claude quota shows its account');
    X.clk({provider:'grok'});assert.ok(/quota-value num warning">0%/.test(quotaHtml()));
    console.log('real snapshot checked: '+real.datasets.length+' datasets, '+real.limits.length+' limits');
  }
};
