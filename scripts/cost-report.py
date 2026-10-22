#!/usr/bin/env python3
"""Add up the AI cost lines ("usage {...}") from the server log.

  ssh -i ~/.ssh/clarvy_deploy clarvy@62.171.184.161 'journalctl -u clarvy --since "7 days ago" -o cat' | python3 scripts/cost-report.py

Costs are estimates from the list prices in lib/core.js (PRICE_* env vars), not an OpenAI invoice.
"""
import json, sys
from collections import defaultdict

calls = []
for line in sys.stdin:
    i = line.find("usage {")
    if i < 0:
        continue
    try:
        calls.append(json.loads(line[i + 6:]))
    except ValueError:
        pass
if not calls:
    sys.exit("No usage lines found.")

by_kind = defaultdict(lambda: [0, 0.0, 0, 0, 0])
by_room = defaultdict(float)
for c in calls:
    k = by_kind[c.get("kind", "other")]
    k[0] += 1; k[1] += c.get("cost", 0); k[2] += c.get("in", 0); k[3] += c.get("out", 0); k[4] += c.get("searches", 0)
    if c.get("room"):
        by_room[c["room"]] += c.get("cost", 0)

print(f"{'kind':<12}{'calls':>6}{'total $':>10}{'avg $':>9}{'avg in':>9}{'avg out':>9}{'searches':>10}")
for kind, (n, cost, tin, tout, srch) in sorted(by_kind.items(), key=lambda x: -x[1][1]):
    print(f"{kind:<12}{n:>6}{cost:>10.3f}{cost / n:>9.3f}{tin // n:>9}{tout // n:>9}{srch:>10}")
total = sum(c.get("cost", 0) for c in calls)
print(f"\nAll calls: {len(calls)}, about ${total:.2f}")
if by_room:
    vals = sorted(by_room.values())
    print(f"Decide runs per room: {len(vals)} rooms, average ${sum(vals) / len(vals):.2f}, highest ${vals[-1]:.2f}")
