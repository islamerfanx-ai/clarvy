// Decision Rooms math: score every option through each member's eyes, then combine for the group.
// Plain code, no AI calls, so it costs nothing per member (spec: "How the combined view works").
// Used by the server (lib/rooms.js) and by the in-browser demo.

// Risk appetite as a power on outcome value: below 1 fears the worst case, above 1 chases the best.
export const RISK_POWER = { safe: 0.5, balanced: 1, bold: 1.6 };

// Spread `total` across keys in proportion to `shares`, rounding so the parts still sum exactly.
export function apportion(keys, shares, total = 100) {
  const sum = keys.reduce((s, k) => s + (Number(shares[k]) || 0), 0);
  const raw = keys.map(k => sum > 0 ? (Number(shares[k]) || 0) / sum * total : total / keys.length);
  const out = raw.map(Math.floor);
  let left = total - out.reduce((a, b) => a + b, 0);
  raw.map((r, i) => [r - out[i], i]).sort((a, b) => b[0] - a[0]).forEach(([, i]) => { if (left > 0) { out[i]++; left--; } });
  return Object.fromEntries(keys.map((k, i) => [k, out[i]]));
}

// A member's 1-5 "how much does it matter" ratings become whole-number weights summing to 100.
export const ratingsToWeights = (ratings, ids) => apportion(ids, Object.fromEntries(ids.map(id => [id, ratings[id] ?? 3])), 100);

const num = (v, lo, hi, dflt) => { const n = Number(v); return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : dflt; };
const mean = xs => xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0;
const r1 = x => Math.round(x * 10) / 10;
function shuffle(xs) { const a = [...xs]; for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; }

// Certainty equivalent (0-10) of an option's best/likely/worst outcomes for risk power a.
function certainty(outs, a) {
  const total = outs.reduce((s, o) => s + o.odds, 0) || 1;
  const eu = outs.reduce((s, o) => s + o.odds / total * Math.pow(o.value / 10, a), 0);
  return 10 * Math.pow(eu, 1 / a);
}

/**
 * options:  [{id,label}]           criteria: [{id,label}]
 * scores:   {optionId: {criterionId: 0-10}}         (from the Analyst)
 * outcomes: {optionId: {best|likely|worst: {value 0-10, odds 0-100}}}
 * inputs:   [{weights, risk_appetite, gut_pick, concern}]  (private; never returned per person)
 */
export function roomMath({ options, criteria, scores, outcomes, inputs }) {
  const oids = options.map(o => o.id), cids = criteria.map(c => c.id);
  const sc = (o, c) => num(scores?.[o]?.[c], 0, 10, 5);
  const outs = o => ["best", "likely", "worst"].map(k => ({ value: num(outcomes?.[o]?.[k]?.value, 0, 10, 5), odds: num(outcomes?.[o]?.[k]?.odds, 0, 100, 33) }));
  const best = (ids, f) => ids.reduce((b, o) => f(o) > f(b) ? o : b, ids[0]);

  // Each member: how well each option fits their weights (60%) and their appetite for its outcomes (40%).
  const members = inputs.map(inp => {
    const a = RISK_POWER[inp.risk_appetite] ?? 1;
    const per = {};
    for (const o of oids) {
      const fit = cids.reduce((s, c) => s + (Number(inp.weights?.[c]) || 0) / 100 * sc(o, c), 0);
      per[o] = r1(0.6 * fit + 0.4 * certainty(outs(o), a));
    }
    return { per, winner: best(oids, o => per[o]), gut: inp.gut_pick, risk: inp.risk_appetite, weights: inp.weights || {}, concern: String(inp.concern || "").trim() };
  });

  // Group: equal weight per member in v1.
  const group = Object.fromEntries(oids.map(o => [o, r1(mean(members.map(m => m.per[o])))]));
  const ranked = [...oids].sort((x, y) => group[y] - group[x]);
  const call = ranked[0];
  const tally = key => Object.fromEntries(oids.map(o => [o, members.filter(m => m[key] === o).length]));
  const dissent = members.filter(m => m.winner !== call).length;

  return {
    members: members.length,
    group, ranked, call,
    safest: best(oids, o => outs(o)[2].value),
    // dominated: some other option is at least as good on every criterion and better on one
    dominated: oids.filter(o => oids.some(p => p !== o && cids.every(c => sc(p, c) >= sc(o, c)) && cids.some(c => sc(p, c) > sc(o, c)))),
    winners: tally("winner"),
    gut: tally("gut"),
    riskMix: Object.fromEntries(Object.keys(RISK_POWER).map(k => [k, members.filter(m => m.risk === k).length])),
    weightSpread: criteria.map(c => {
      const ws = members.map(m => Number(m.weights[c.id]) || 0);
      const min = Math.min(...ws), max = Math.max(...ws);
      return { id: c.id, label: c.label, min, max, avg: Math.round(mean(ws)), split: max - min >= 25 };
    }),
    dissent,
    capConfidence: dissent >= 2,   // spec: two or more personal winners differ -> confidence at most Medium
    // Anonymous and shuffled, so a row can't be matched to a person by order.
    memberScores: shuffle(members.map(m => ({ winner: m.winner, scores: m.per }))).map((m, i) => ({ member: i + 1, ...m })),
    concerns: shuffle(members.map(m => m.concern).filter(Boolean))
  };
}
