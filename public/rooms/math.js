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

  // Each member's view of each option, from their whole answer: how well it fits what they weigh (45%),
  // their appetite for its outcomes (25%), and whether it is the option they said they lean to (30%).
  // Without the gut pick, the Analyst's scores decided every member's winner and hid real splits.
  const members = inputs.map(inp => {
    const a = RISK_POWER[inp.risk_appetite] ?? 1;
    const per = {};
    for (const o of oids) {
      const fit = cids.reduce((s, c) => s + (Number(inp.weights?.[c]) || 0) / 100 * sc(o, c), 0);
      per[o] = r1(0.45 * fit + 0.25 * certainty(outs(o), a) + (inp.gut_pick === o ? 3 : 0));
    }
    return { per, winner: best(oids, o => per[o]), gut: inp.gut_pick, risk: inp.risk_appetite, weights: inp.weights || {}, concern: String(inp.concern || "").trim() };
  });

  // Group: equal weight per member in v1.
  const group = Object.fromEntries(oids.map(o => [o, r1(mean(members.map(m => m.per[o])))]));
  const ranked = [...oids].sort((x, y) => group[y] - group[x]);
  const call = ranked[0];
  const tally = key => Object.fromEntries(oids.map(o => [o, members.filter(m => m[key] === o).length]));
  const dissent = members.filter(m => m.winner !== call).length;
  const n = members.length;
  const gutTally = tally("gut");
  const gutTop = best(oids, o => gutTally[o]);
  const gutAgainst = members.filter(m => m.gut && m.gut !== call).length;
  const riskMix = Object.fromEntries(Object.keys(RISK_POWER).map(k => [k, members.filter(m => m.risk === k).length]));
  // The room is split when a real share of people end up somewhere else than the call, by their
  // whole answer or by their gut, or when cautious and bold members pull hard both ways.
  const split = n >= 2 && (dissent >= Math.max(2, Math.ceil(n / 3)) || gutAgainst / n >= 0.5 ||
    (riskMix.safe >= Math.ceil(n / 3) && riskMix.bold >= Math.ceil(n / 3)));
  // Most of the room leaned to a different option than the numbers favour: say so up front.
  const gutMismatch = gutTop !== call && gutTally[gutTop] > (gutTally[call] || 0) ? { gut: gutTop, call, leaning: gutTally[gutTop], members: n } : null;

  return {
    members: members.length,
    group, ranked, call,
    safest: best(oids, o => outs(o)[2].value),
    // dominated: some other option is at least as good on every criterion and better on one
    dominated: oids.filter(o => oids.some(p => p !== o && cids.every(c => sc(p, c) >= sc(o, c)) && cids.some(c => sc(p, c) > sc(o, c)))),
    winners: tally("winner"),
    gut: gutTally,
    riskMix,
    weightSpread: criteria.map(c => {
      const ws = members.map(m => Number(m.weights[c.id]) || 0);
      const min = Math.min(...ws), max = Math.max(...ws);
      return { id: c.id, label: c.label, min, max, avg: Math.round(mean(ws)), split: max - min >= 25 };
    }),
    dissent, gutAgainst, split, gutMismatch,
    capConfidence: split,          // a split room's call is at most Medium confidence
    // Anonymous and shuffled, so a row can't be matched to a person by order.
    memberScores: shuffle(members.map(m => ({ winner: m.winner, scores: m.per }))).map((m, i) => ({ member: i + 1, ...m })),
    concerns: shuffle(members.map(m => m.concern).filter(Boolean)),
    // Group totals for "The numbers" panel: enough to rebuild the group score exactly, nothing per person.
    // In rooms of 1 or 2 the average weight is rounded, as in the map, so nobody can work out another's answer.
    whatif: {
      n, exact: n >= 3, gut: gutTally, risk: riskMix,
      weights: Object.fromEntries(criteria.map(c => {
        const avg = mean(members.map(m => Number(m.weights[c.id]) || 0));
        return [c.id, n >= 3 ? Math.round(avg * 1000) / 1000 : Math.round(avg)];
      }))
    }
  };
}

/* ======================= The numbers (what if) ======================= */
// The group score is linear in the weights and depends on risk only through each appetite's share, so it
// can be rebuilt from group totals alone: average weights, the risk mix and the gut-pick tally.
// agg: {n, weights: {cid: 0-100}, risk: {safe, balanced, bold}, gut: {oid: count}}
// opts: {ignoreGut, riskShift: -1 more cautious | 0 | 1 bolder}
export function shiftRisk(risk, shift) {
  const r = { safe: risk.safe || 0, balanced: risk.balanced || 0, bold: risk.bold || 0 };
  if (shift < 0) return { safe: r.safe + r.balanced, balanced: r.bold, bold: 0 };
  if (shift > 0) return { safe: 0, balanced: r.safe, bold: r.balanced + r.bold };
  return r;
}
export function groupFromAggregates({ options, criteria, scores, outcomes, agg }, { ignoreGut = false, riskShift = 0 } = {}) {
  const oids = options.map(o => o.id), cids = criteria.map(c => c.id);
  const sc = (o, c) => num(scores?.[o]?.[c], 0, 10, 5);
  const outs = o => ["best", "likely", "worst"].map(k => ({ value: num(outcomes?.[o]?.[k]?.value, 0, 10, 5), odds: num(outcomes?.[o]?.[k]?.odds, 0, 100, 33) }));
  const n = Math.max(1, Number(agg.n) || 1);
  const wsum = cids.reduce((s, c) => s + (Number(agg.weights?.[c]) || 0), 0) || 1;
  const risk = shiftRisk(agg.risk || {}, riskShift);
  const rsum = Object.values(risk).reduce((a, b) => a + b, 0) || 1;
  const group = {};
  for (const o of oids) {
    const fit = cids.reduce((s, c) => s + (Number(agg.weights?.[c]) || 0) / wsum * sc(o, c), 0);
    const cert = Object.entries(risk).reduce((s, [k, cnt]) => s + cnt / rsum * certainty(outs(o), RISK_POWER[k] ?? 1), 0);
    const gut = ignoreGut ? 0 : 3 * (Number(agg.gut?.[o]) || 0) / n;
    group[o] = Math.round((0.45 * fit + 0.25 * cert + gut) * 100) / 100;
  }
  const ranked = [...oids].sort((x, y) => group[y] - group[x]);
  return { group, ranked, top: ranked[0], close: ranked.length > 1 && group[ranked[0]] - group[ranked[1]] < 0.2 };
}
// Set one criterion's share of the weight to `to` (0-100) and spread the rest over the others in proportion.
export function setWeight(weights, cids, cid, to) {
  const rest = cids.filter(c => c !== cid), restSum = rest.reduce((s, c) => s + (Number(weights[c]) || 0), 0);
  const out = { [cid]: to };
  rest.forEach(c => { out[c] = restSum > 0 ? (Number(weights[c]) || 0) / restSum * (100 - to) : (100 - to) / rest.length; });
  return out;
}
// What would flip it: the smallest change to one criterion's weight that puts another option first.
export function flipPoint(room, opts = {}) {
  const cids = room.criteria.map(c => c.id);
  const base = groupFromAggregates(room, opts);
  const wsum = cids.reduce((s, c) => s + (Number(room.agg.weights?.[c]) || 0), 0) || 1;
  const now = Object.fromEntries(cids.map(c => [c, (Number(room.agg.weights?.[c]) || 0) / wsum * 100]));
  let found = null;
  for (const cid of cids) {
    for (let step = 1; step <= 100; step++) {
      for (const dir of [1, -1]) {
        const to = Math.round(now[cid]) + dir * step;
        if (to < 0 || to > 100) continue;
        const r = groupFromAggregates({ ...room, agg: { ...room.agg, weights: setWeight(now, cids, cid, to) } }, opts);
        if (r.top !== base.top) {
          if (!found || step < found.step) found = { step, criterion: cid, from: Math.round(now[cid]), to, top: r.top };
          step = 101; break;
        }
      }
    }
  }
  return found;   // null: no single weight change flips it
}
