#!/usr/bin/env python3
"""Measure how epic children wait, for docs/design/epic-aware-scheduling.md.

Read-only. Opens the database with SQLite's `mode=ro` URI, so it cannot
write to the live file. To freeze the numbers, snapshot first with
sqlite3's backup() and point the script at the copy:

    python3 measure_epic_waits.py ~/.arbiter/arbiter.sqlite3 \
        --as-of 2026-10-01T23:07:33Z --workspace bd

Prints every table the design doc quotes in section 2:
  * Ready wait for head, middle and tail children (by close order)
  * the same split inside priority P2 only, and by own priority
  * whether an epic floor would lift the child (own priority worse than the
    epic's)
  * where head and tail children spend their open time
  * how often a Ready child was passed over by a newer ticket
  * completion curves for selected epics
  * how many epics are started but unfinished, per day

Method notes (also in the doc's appendix A):
  * `ticket_transitions` stores lifecycle states, so Ready and Blocked are both
    `queued`. A queued span counts as Ready only after every gating blocker
    (`depends_on` targets, `blocks` sources) has closed, using today's edges
    and each blocker's latest `closed_at`.
  * "Head / middle / tail" is a child's position in its epic's close order:
    the first 50%, 50-80% and the last 20% of siblings to close.
  * Most rows before 2026-10-01 are `source = backfill`, rebuilt from
    `issues_versions` (bd-d8fi92).
"""

import argparse
import collections
import datetime as dt
import math
import sqlite3
import statistics as st

UTC = dt.timezone.utc


def ts(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


class Data:
    def __init__(self, path, as_of):
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        self.now = as_of
        self.issues = {}
        for row in conn.execute(
            "select id, priority, state, issue_type, created_at, closed_at, title "
            "from issues"
        ):
            self.issues[row[0]] = {
                "prio": row[1],
                "state": row[2],
                "type": row[3],
                "created": ts(row[4]),
                "closed": ts(row[5]),
                "title": row[6],
            }
        self.kids, self.parents, self.gates = {}, {}, {}
        for src, dst, kind in conn.execute(
            "select from_issue_id, to_issue_id, type from dependencies"
        ):
            if kind == "parent_of":
                self.kids.setdefault(src, []).append(dst)
                self.parents.setdefault(dst, []).append(src)
            elif kind == "depends_on":
                self.gates.setdefault(src, []).append(dst)
            elif kind == "blocks":
                self.gates.setdefault(dst, []).append(src)
        self.trans = {}
        for tid, frm, to, at in conn.execute(
            "select ticket_id, from_state, to_state, at from ticket_transitions "
            "order by at, id"
        ):
            at = ts(at)
            if at <= self.now:
                self.trans.setdefault(tid, []).append((frm, to, at))

    def is_epic(self, tid):
        return self.issues.get(tid, {}).get("type") == "epic"

    def closed_by(self, tid, at):
        i = self.issues[tid]
        return i["state"] == "closed" and i["closed"] is not None and i["closed"] <= at

    def leaves(self, epic, seen=None):
        """Non-epic descendants through nested epics, cycle-guarded."""
        seen = seen if seen is not None else set()
        out = []
        for kid in self.kids.get(epic, []):
            if kid in seen or kid not in self.issues:
                continue
            seen.add(kid)
            out += self.leaves(kid, seen) if self.is_epic(kid) else [kid]
        return out

    def ready_spans(self, tid):
        spans, cur = [], None
        for frm, to, at in self.trans.get(tid, []):
            if to == "queued" and cur is None:
                cur = at
            elif frm == "queued" and to != "queued" and cur is not None:
                spans.append((cur, at, to))
                cur = None
        if cur is not None:
            spans.append((cur, None, None))
        return spans

    def unblocked_at(self, tid):
        closes = [self.issues[b]["closed"] for b in self.gates.get(tid, []) if b in self.issues]
        if any(c is None or c > self.now for c in closes):
            return None
        return max(closes) if closes else dt.datetime.min.replace(tzinfo=UTC)

    def ready_wait(self, tid):
        """Hours queued and unblocked; and whether the ticket is still queued."""
        unblocked = self.unblocked_at(tid)
        total, still_open = 0.0, False
        for start, end, _ in self.ready_spans(tid):
            if end is None:
                still_open = True
            if unblocked is None:
                continue
            s, e = max(start, unblocked), end or self.now
            if e > s:
                total += (e - s).total_seconds() / 3600
        return total, still_open

    def first_start(self, tid):
        for _, to, at in self.trans.get(tid, []):
            if to == "active":
                return at
        return None

    def state_hours(self, tid):
        out = collections.Counter()
        unblocked = self.unblocked_at(tid)
        rows = self.trans.get(tid, [])
        for n, (_, to, at) in enumerate(rows):
            if to == "closed" or n + 1 >= len(rows):
                continue
            end = rows[n + 1][2]
            hours = (end - at).total_seconds() / 3600
            if to != "queued":
                out[to] += hours
            elif unblocked is None or unblocked >= end:
                out["blocked"] += hours
            else:
                split = max(at, unblocked)
                out["blocked"] += (split - at).total_seconds() / 3600
                out["ready"] += (end - split).total_seconds() / 3600
        return out


def summary(label, values):
    if not values:
        print(f"  {label:34s} n=0")
        return
    values = sorted(values)
    pct = lambda f: values[min(len(values) - 1, int(f * len(values)))]
    print(
        f"  {label:34s} n={len(values):3d}  median={st.median(values):5.1f}h  "
        f"p75={pct(0.75):5.1f}h  p90={pct(0.90):5.1f}h  mean={st.mean(values):5.1f}h"
    )


def epic_children(d, prefix):
    """One row per non-epic child (direct parent is an epic) with a Ready span."""
    rows = []
    for epic, kids in d.kids.items():
        if not d.is_epic(epic) or not epic.startswith(prefix):
            continue
        kids = [k for k in kids if k in d.issues and not d.is_epic(k)]
        if len(kids) < 3:
            continue
        order = sorted(
            (k for k in kids if d.closed_by(k, d.now)), key=lambda k: d.issues[k]["closed"]
        )
        for kid in kids:
            if not d.ready_spans(kid):
                continue
            wait, still_open = d.ready_wait(kid)
            rows.append(
                {
                    "id": kid,
                    "epic": epic,
                    "prio": d.issues[kid]["prio"],
                    "epic_prio": d.issues[epic]["prio"],
                    "wait": wait,
                    "open": still_open,
                    "pos": order.index(kid) / (len(kids) - 1) if kid in order else None,
                }
            )
    return rows


BUCKETS = [
    ("head (first 50% to close)", lambda p: p < 0.5),
    ("middle (50-80%)", lambda p: 0.5 <= p < 0.8),
    ("tail (last 20% to close)", lambda p: p >= 0.8),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("db")
    ap.add_argument("--as-of", help="UTC ISO timestamp; default now")
    ap.add_argument("--workspace", default="bd", help="ticket id prefix")
    ap.add_argument(
        "--curves",
        default="bd-ibiwci,bd-dqvv90,bd-de2g19,bd-9dr65f,bd-cv1inp,bd-4i9az1,"
        "bd-3sa0y9,bd-blrsde,bd-22hgkx",
    )
    args = ap.parse_args()
    as_of = ts(args.as_of) if args.as_of else dt.datetime.now(UTC)
    d = Data(args.db, as_of)
    prefix = args.workspace + "-"
    print(f"as of {as_of.isoformat()}  workspace prefix {prefix!r}\n")

    rows = epic_children(d, prefix)
    done = [r for r in rows if r["pos"] is not None and not r["open"]]
    print(f"1. Ready wait (queued and unblocked), closed epic children: {len(done)}")
    for label, test in BUCKETS:
        summary(label, [r["wait"] for r in done if test(r["pos"])])
    print("   inside own priority P2 only:")
    for label, test in BUCKETS:
        summary(label, [r["wait"] for r in done if test(r["pos"]) and r["prio"] == 2])
    print("   by own priority, epic children vs tickets with no parent:")
    loose = []
    for tid, i in d.issues.items():
        if (
            tid.startswith(prefix)
            and tid not in d.parents
            and i["type"] != "epic"
            and d.closed_by(tid, d.now)
            and d.ready_spans(tid)
        ):
            loose.append((i["prio"], d.ready_wait(tid)[0]))
    for p in range(5):
        summary(f"P{p} epic child", [r["wait"] for r in done if r["prio"] == p])
        summary(f"P{p} no parent", [w for q, w in loose if q == p])
    # ES7 guard metric: the epic floor must not slow tickets that have no parent.
    summary("GUARD: no parent, P1+P2", [w for q, w in loose if q in (1, 2)])

    print("\n2. Priority mix and floor lift by close position")
    for label, test in BUCKETS:
        sel = [r for r in done if test(r["pos"])]
        mix = {f"P{p}": sum(1 for r in sel if r["prio"] == p) for p in range(5)}
        lifted = sum(1 for r in sel if r["prio"] > r["epic_prio"])
        print(f"  {label:34s} {mix}  own worse than epic: {lifted}/{len(sel)}")
    summary("would be lifted by epic priority", [r["wait"] for r in done if r["prio"] > r["epic_prio"]])
    summary("would not be lifted", [r["wait"] for r in done if r["prio"] <= r["epic_prio"]])

    print("\n3. Mean hours per child in each state (closed epic children)")
    for label, test in [BUCKETS[0], BUCKETS[2]]:
        sel = [r for r in done if test(r["pos"])]
        total = collections.Counter()
        for r in sel:
            total.update(d.state_hours(r["id"]))
        print(f"  {label:34s} " + "  ".join(f"{k} {v / len(sel):.1f}" for k, v in sorted(total.items())))

    print("\n4. Passed over: tickets started while this child sat Ready, that entered Ready after it")
    starts = []
    for tid in d.trans:
        if tid.startswith(prefix):
            for start, end, to in d.ready_spans(tid):
                if end and to == "active":
                    starts.append((end, start, tid))
    for label, test in [BUCKETS[0], BUCKETS[2]]:
        sel = [r for r in done if test(r["pos"])]
        counts, by_prio = [], collections.Counter()
        for r in sel:
            unblocked, n = d.unblocked_at(r["id"]), 0
            for start, end, _ in d.ready_spans(r["id"]):
                if unblocked is None:
                    continue
                s, e = max(start, unblocked), end or d.now
                for started, entered, other in starts:
                    if s < started < e and entered > s and other != r["id"]:
                        n += 1
                        by_prio[d.issues[other]["prio"]] += 1
            counts.append(n)
        print(
            f"  {label:34s} n={len(sel)} median={st.median(counts)} mean={st.mean(counts):.1f} "
            f"max={max(counts)}  passed over by P{dict(sorted(by_prio.items()))}"
        )

    print("\n5. Open epic children by state")
    tally = collections.Counter()
    for epic in d.kids:
        if d.is_epic(epic) and epic.startswith(prefix):
            for kid in d.kids[epic]:
                i = d.issues.get(kid)
                if i and i["type"] != "epic" and i["state"] != "closed":
                    gated = "blocked" if d.unblocked_at(kid) is None else "unblocked"
                    tally[(i["state"], gated)] += 1
    for key, n in sorted(tally.items()):
        print(f"  {key[0]:9s} {key[1]:9s} {n}")

    print("\n6. Completion curves: % of leaf descendants closed, days after the first was filed")
    days = [1, 2, 3, 5, 7, 10, 14]
    print("  epic        n  " + " ".join(f"d{x:<4d}" for x in days) + " now")
    for epic in args.curves.split(","):
        leaves = d.leaves(epic)
        if not leaves:
            continue
        t0 = min(d.issues[k]["created"] for k in leaves)
        cells = []
        for x in days:
            at = t0 + dt.timedelta(days=x)
            if at > d.now:
                cells.append("  .  ")
            else:
                pct = 100 * sum(d.closed_by(k, at) for k in leaves) / len(leaves)
                cells.append(f"{pct:4.0f}%")
        now = 100 * sum(d.closed_by(k, d.now) for k in leaves) / len(leaves)
        print(f"  {epic:10s} {len(leaves):2d}  " + " ".join(cells) + f" {now:4.0f}%")
    shares = []
    for epic in d.kids:
        if not d.is_epic(epic):
            continue
        leaves = d.leaves(epic)
        if len(leaves) < 5 or not all(d.closed_by(k, d.now) for k in leaves):
            continue
        t0 = min(d.issues[k]["created"] for k in leaves)
        closes = sorted(d.issues[k]["closed"] for k in leaves)
        t80 = closes[math.ceil(0.8 * len(leaves)) - 1]
        elapsed = (closes[-1] - t0).total_seconds()
        if elapsed > 0:
            shares.append((closes[-1] - t80).total_seconds() / elapsed)
    if shares:
        print(
            f"  finished epics (all workspaces, >=5 leaves): {len(shares)}; median share of "
            f"elapsed time spent on the last 20%: {st.median(shares):.2f}"
        )

    print("\n7. Epics started but unfinished, per day")
    epics = [e for e in d.kids if d.is_epic(e) and e.startswith(prefix)]
    for back in range(14, -1, -1):
        at = d.now - dt.timedelta(days=back)
        unfinished = touched = 0
        for epic in epics:
            leaves = d.leaves(epic)
            starts_ = [d.first_start(k) for k in leaves]
            if any(s and s <= at for s in starts_) and not all(d.closed_by(k, at) for k in leaves):
                unfinished += 1
            if any(s and at - dt.timedelta(days=1) < s <= at for s in starts_):
                touched += 1
        print(f"  {at.date()}  started-unfinished {unfinished}  had a child started in prior 24h {touched}")


if __name__ == "__main__":
    main()
