'use strict';
// Shared by the browser and dependency-free tests. All periods end at snapshot.period.to.
module.exports = function usageCore(snapshot) {
  const number = v => typeof v === 'number' && Number.isFinite(v) && v >= 0;
  const shift = (date, n) => new Date(Date.parse(date + 'T00:00:00Z') + n * 86400000).toISOString().slice(0, 10);
  // 7d/30d always end at snapshot.period.to. 'all' starts at the selected dataset's first day, or the global horizon when it has none.
  function firstDate(dataset) { const ds = (dataset?.days || []).map(d => d?.date).filter(v => /^\d{4}-\d{2}-\d{2}$/.test(v || '')).sort(); return ds.length && ds[0] <= snapshot.period.to ? ds[0] : null; }
  function bounds(period, dataset) { const to = snapshot.period.to; return {from: period === 'all' ? (firstDate(dataset) || snapshot.period.from) : shift(to, -(period === '30d' ? 29 : 6)), to}; }
  function days(dataset, period) {
    const b = bounds(period, dataset), map = new Map((dataset.days || []).map(d => [d.date, d])), rows = [];
    for (let date = b.from; date <= b.to; date = shift(date, 1)) {
      const d = map.get(date);
      rows.push(d && d.coverageStatus !== 'missing' ? {...d} : {date, tokens:null, input:null, output:null, cacheRead:null, cacheCreate:null, reasoning:null, records:null, coverageStatus:'missing'});
    }
    return rows;
  }
  function sum(rows, key = 'tokens') {
    const known = rows.filter(r => number(r[key]));
    return known.length ? known.reduce((n, r) => n + r[key], 0) : null;
  }
  function groups(dataset, period, dim) {
    const b = bounds(period, dataset), m = new Map();
    for (const r of dataset.breakdowns?.[dim] || []) {
      if (r.date < b.from || r.date > b.to) continue;
      const id = r.label || 'unknown';
      if (!m.has(id)) m.set(id, {label:id, values:[]});
      m.get(id).values.push({tokens:r.totals?.total});
    }
    return [...m.values()].map(r => ({label:r.label, tokens:sum(r.values)})).sort((a,b) => (b.tokens ?? -1) - (a.tokens ?? -1));
  }
  function compare(dataset, period) {
    if (period === 'all' || !dataset.coverage?.comparisonSafe) return {safe:false};
    const current = days(dataset, period), count = current.length, b = bounds(period, dataset);
    const map = new Map((dataset.days || []).map(d => [d.date, d]));
    const previous = Array.from({length:count}, (_,i) => map.get(shift(b.from, i - count)));
    const complete = r => r && r.coverageStatus === 'observed' && number(r.tokens) && dataset.latestCompleteDate && r.date <= dataset.latestCompleteDate && !(dataset.coverage?.missingDates || []).includes(r.date);
    if (!current.every(complete) || !previous.every(complete)) return {safe:false};
    const a = sum(current), z = sum(previous);
    return {safe:true, current:a, previous:z, difference:a-z, percent:z === 0 ? null : (a-z)/z*100, from:shift(b.from,-count),to:shift(b.from,-1)};
  }
  return {number,shift,bounds,firstDate,days,sum,groups,compare};
};
