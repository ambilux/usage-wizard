#!/usr/bin/env python3
"""Claude Code usage dashboard.

Reads ONLY local files in ~/.claude/projects (Claude Code session logs)
and writes a single HTML file. No packages, no network.

    python3 build.py            -> dashboard.html next to this script
"""
import glob
import html
import json
import os
import statistics
from collections import Counter, defaultdict
from datetime import datetime, timezone

LOG_DIR = os.path.expanduser("~/.claude/projects")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboard.html")

# Thresholds for the suggestions
LONG_CONTEXT = 120_000      # context size where /clear or /compact pays off
LONG_TURNS = 120            # responses per session
CACHE_GAP_MIN = 60          # pause in minutes after which the cache usually expires
SMALL_OUTPUT = 400          # "small" response in output tokens


def esc(s):
    return html.escape(str(s))


def fmt(n):
    n = float(n)
    for unit, div in (("B", 1e9), ("M", 1e6), ("k", 1e3)):
        if abs(n) >= div:
            return f"{n / div:.1f}{unit}"
    return f"{int(n)}"


def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def project_name(cwd, folder):
    if cwd:
        return os.path.basename(cwd.rstrip("/")) or cwd
    return folder.split("-")[-1]


def load():
    msgs = {}            # (message.id, requestId) -> record (duplicated per content block)
    titles, costs, cwds = {}, {}, {}
    tools = Counter()
    for path in glob.glob(os.path.join(LOG_DIR, "**", "*.jsonl"), recursive=True):
        folder = os.path.basename(os.path.dirname(path))
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                sid = d.get("sessionId")
                t = d.get("type")
                if t == "custom-title" and sid:
                    titles[sid] = d.get("customTitle")
                elif t == "cost-state" and sid:
                    costs[sid] = d.get("totalCostUSD") or 0
                if d.get("cwd") and sid:
                    cwds[sid] = d["cwd"]
                if t != "assistant":
                    continue
                m = d.get("message") or {}
                u = m.get("usage")
                if not u or m.get("model") in (None, "<synthetic>"):
                    continue
                for b in m.get("content") or []:
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        tools[b.get("name", "?")] += 1
                key = (m.get("id"), d.get("requestId"))
                msgs[key] = {
                    "sid": sid,
                    "folder": folder,
                    "cwd": d.get("cwd"),
                    "ts": parse_ts(d.get("timestamp", "")),
                    "model": m.get("model"),
                    "effort": d.get("effort") or "",
                    "inp": u.get("input_tokens", 0) or 0,
                    "cw": u.get("cache_creation_input_tokens", 0) or 0,
                    "cr": u.get("cache_read_input_tokens", 0) or 0,
                    "out": u.get("output_tokens", 0) or 0,
                    "think": (u.get("output_tokens_details") or {}).get("thinking_tokens", 0) or 0,
                }
    rows = sorted((r for r in msgs.values() if r["ts"]), key=lambda r: r["ts"])
    return rows, titles, costs, cwds, tools


def analyse(rows, titles, costs, cwds, tools):
    tot = Counter()
    by_day = defaultdict(Counter)
    by_proj = defaultdict(Counter)
    by_model = Counter()
    sessions = defaultdict(list)
    for r in rows:
        r["ctx"] = r["inp"] + r["cw"] + r["cr"]
        for k in ("inp", "cw", "cr", "out", "think"):
            tot[k] += r[k]
        day = r["ts"].astimezone().strftime("%Y-%m-%d")
        for k in ("inp", "cw", "cr", "out"):
            by_day[day][k] += r[k]
        proj = project_name(r["cwd"] or cwds.get(r["sid"]), r["folder"])
        by_proj[proj]["total"] += r["ctx"] + r["out"]
        by_proj[proj]["out"] += r["out"]
        by_model[r["model"]] += r["ctx"] + r["out"]
        sessions[r["sid"]].append(r)

    sess = []
    for sid, rs in sessions.items():
        gaps = 0
        for a, b in zip(rs, rs[1:]):
            if (b["ts"] - a["ts"]).total_seconds() > CACHE_GAP_MIN * 60 and b["cw"] > 20_000:
                gaps += 1
        outs = [r["out"] for r in rs]
        cwd = rs[0]["cwd"] or cwds.get(sid)
        sess.append({
            "sid": sid,
            "title": titles.get(sid) or sid[:8],
            "proj": project_name(cwd, rs[0]["folder"]),
            "cwd": cwd,
            "start": rs[0]["ts"].astimezone(),
            "turns": len(rs),
            "peak": max(r["ctx"] for r in rs),
            "total": sum(r["ctx"] + r["out"] for r in rs),
            "out": sum(outs),
            "median_out": statistics.median(outs),
            "models": Counter(r["model"] for r in rs),
            "efforts": Counter(r["effort"] for r in rs if r["effort"]),
            "cache_gaps": gaps,
            "cost": costs.get(sid),
        })
    sess.sort(key=lambda s: s["total"], reverse=True)

    inputs = tot["inp"] + tot["cw"] + tot["cr"]
    cache_rate = tot["cr"] / inputs if inputs else 0
    return {
        "tot": tot, "inputs": inputs, "cache_rate": cache_rate,
        "by_day": dict(sorted(by_day.items())), "by_proj": by_proj,
        "by_model": by_model, "sessions": sess, "tools": tools,
        "first": rows[0]["ts"].astimezone() if rows else None,
        "last": rows[-1]["ts"].astimezone() if rows else None,
    }


def tips(a):
    out = []  # (weight, title, text)
    for s in a["sessions"]:
        if s["peak"] >= LONG_CONTEXT or s["turns"] >= LONG_TURNS:
            out.append((s["total"], f"Long session: \"{s['title']}\"",
                        f"{s['turns']} responses, context up to {fmt(s['peak'])} tokens. Every response resends the "
                        f"whole history. Use <code>/clear</code> for a new subtask, <code>/compact</code> to keep "
                        f"going on the same one."))
        opus = sum(n for m, n in s["models"].items() if "opus" in (m or ""))
        if opus / s["turns"] > 0.8 and s["median_out"] < SMALL_OUTPUT and s["turns"] >= 15:
            out.append((s["total"] * 0.5, f"Opus for small steps: \"{s['title']}\"",
                        f"The typical response was only {int(s['median_out'])} tokens. For routine work like this, "
                        f"Sonnet or a lower effort level is often enough."))
        if s["cache_gaps"]:
            out.append((s["total"] * 0.3, f"Cache rebuilt: \"{s['title']}\"",
                        f"{s['cache_gaps']}× the context had to be rewritten to the cache after a pause of over "
                        f"{CACHE_GAP_MIN} min. After a long break, start a new session instead of resuming a huge one."))
    seen = set()
    for s in a["sessions"]:
        cwd = s["cwd"]
        if not cwd or cwd in seen or not os.path.isdir(cwd):
            continue
        seen.add(cwd)
        if not os.path.exists(os.path.join(cwd, "CLAUDE.md")):
            proj_total = a["by_proj"][s["proj"]]["total"]
            out.append((proj_total * 0.4, f"No CLAUDE.md in \"{s['proj']}\"",
                        f"Without it, Claude has to re-explore the project every session. 10–20 lines on structure, "
                        f"commands and rules are enough (<code>/init</code> creates a draft)."))
    shots = sum(n for t, n in a["tools"].items() if "screen" in t.lower() or "screenshot" in t.lower())
    if shots >= 10:
        out.append((shots * 5000, "Many screenshots",
                    f"{shots} screenshots. Images are expensive in context. Where possible, query state as text "
                    f"instead (console, logs, reading values)."))
    if a["first"] and (a["last"] - a["first"]).days < 25:
        out.append((1, "Short history",
                    "Claude Code deletes old logs after 30 days by default. For longer history, set "
                    "<code>\"cleanupPeriodDays\": 365</code> in <code>~/.claude/settings.json</code>."))
    out.sort(key=lambda t: t[0], reverse=True)
    return out


# ---------- HTML ----------

SERIES = [("cr", "Cache read"), ("cw", "Cache write"), ("inp", "New input"), ("out", "Output")]


def stacked_days(by_day):
    days = list(by_day)
    if not days:
        return "<p class=muted>No data.</p>"
    W, H, pl, pb = 760, 240, 56, 28
    mx = max(sum(c[k] for k, _ in SERIES) for c in by_day.values()) or 1
    bw = min(48, (W - pl) / len(days) - 6)
    parts = []
    for i in range(5):
        v = mx * i / 4
        y = H - pb - (H - pb - 10) * i / 4
        parts.append(f'<line x1="{pl}" x2="{W}" y1="{y}" y2="{y}" class="grid"/>'
                     f'<text x="{pl - 8}" y="{y + 4}" class="axis" text-anchor="end">{fmt(v)}</text>')
    for i, d in enumerate(days):
        x = pl + 6 + i * ((W - pl) / len(days))
        y = H - pb
        c = by_day[d]
        tip = esc(f"{d}\n" + "\n".join(f"{lab}: {fmt(c[k])}" for k, lab in SERIES))
        seg = []
        for j, (k, _) in enumerate(SERIES):
            h = (H - pb - 10) * c[k] / mx
            if h < 0.5:
                continue
            y -= h
            seg.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw:.1f}" height="{max(h - 2, 0.5):.1f}" '
                       f'rx="2" fill="var(--s{j + 1})"/>')
        parts.append(f'<g class="hov" data-tip="{tip}">{"".join(seg)}'
                     f'<rect x="{x - 3:.1f}" y="0" width="{bw + 6:.1f}" height="{H - pb}" fill="transparent"/></g>'
                     f'<text x="{x + bw / 2:.1f}" y="{H - 8}" class="axis" text-anchor="middle">{d[5:]}</text>')
    legend = "".join(f'<span><i style="background:var(--s{j + 1})"></i>{lab}</span>' for j, (_, lab) in enumerate(SERIES))
    return f'<div class="legend">{legend}</div><svg viewBox="0 0 {W} {H}" class="chart">{"".join(parts)}</svg>'


def hbars(items, unit=""):
    items = [(k, v) for k, v in items if v]
    if not items:
        return "<p class=muted>No data.</p>"
    mx = max(v for _, v in items)
    rows = []
    for k, v in items:
        rows.append(f'<div class="hrow hov" data-tip="{esc(k)}: {fmt(v)}{unit}"><span class="hl">{esc(k)}</span>'
                    f'<span class="hb"><b style="width:{100 * v / mx:.1f}%"></b></span>'
                    f'<span class="hv">{fmt(v)}</span></div>')
    return "".join(rows)


def render(a, tip_list):
    t = a["tot"]
    total = a["inputs"] + t["out"]
    opus = sum(v for m, v in a["by_model"].items() if "opus" in (m or ""))
    period = (f"{a['first']:%b %d, %Y} – {a['last']:%b %d, %Y}" if a["first"] else "–")
    tiles = [
        ("Total tokens", fmt(total), f"{fmt(t['out'])} of it output"),
        ("Sessions", str(len(a["sessions"])), period),
        ("Cache hit rate", f"{a['cache_rate'] * 100:.0f}%", "share of input served from cache – higher is cheaper"),
        ("Opus share", f"{100 * opus / total:.0f}%" if total else "–", "of total token volume"),
    ]
    tiles_html = "".join(f'<div class="tile"><div class="tl">{esc(a_)}</div><div class="tv">{b}</div>'
                         f'<div class="ts">{esc(c)}</div></div>' for a_, b, c in tiles)

    tips_html = "".join(f'<li><strong>{esc(ti)}</strong><p>{tx}</p></li>' for _, ti, tx in tip_list) \
        or "<li><strong>All good</strong><p>No notable patterns found.</p></li>"

    srows = []
    for s in a["sessions"]:
        model = ", ".join(f"{m.replace('claude-', '')} ×{n}" for m, n in s["models"].most_common())
        eff = ", ".join(s["efforts"]) or "–"
        warn = " warn" if s["peak"] >= LONG_CONTEXT else ""
        cost = f"${s['cost']:.2f}" if s["cost"] else "–"
        srows.append(f"<tr><td>{esc(s['title'])}</td><td>{esc(s['proj'])}</td><td>{s['start']:%b %d, %H:%M}</td>"
                     f"<td class=n>{s['turns']}</td><td class='n{warn}'>{fmt(s['peak'])}</td>"
                     f"<td class=n>{fmt(s['total'])}</td><td class=n>{fmt(s['out'])}</td>"
                     f"<td>{esc(model)}</td><td>{esc(eff)}</td><td class=n>{cost}</td></tr>")

    projects = sorted(((k, v["total"]) for k, v in a["by_proj"].items()), key=lambda x: -x[1])
    models = sorted(((k.replace("claude-", ""), v) for k, v in a["by_model"].items()), key=lambda x: -x[1])
    tools = a["tools"].most_common(12)
    tools = [(k.replace("mcp__", "").replace("__", " › "), v) for k, v in tools]

    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Claude Code Usage</title>
<style>
.viz-root{{color-scheme:light;--bg:#f4f4f2;--surface-1:#fcfcfb;--line:#e4e3df;--text-primary:#0b0b0b;--text-secondary:#52514e;
--muted:#8a8984;--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a;--s4:#eda100;--warn:#b25b00}}
@media (prefers-color-scheme:dark){{.viz-root{{color-scheme:dark;--bg:#111110;--surface-1:#1a1a19;--line:#2e2e2c;
--text-primary:#f0efec;--text-secondary:#c3c2b7;--muted:#8f8e88;--s1:#3987e5;--s2:#d95926;--s3:#199e70;--s4:#c98500;--warn:#f0a050}}}}
*{{box-sizing:border-box}}body{{margin:0}}
.viz-root{{background:var(--bg);color:var(--text-primary);font:14px/1.45 -apple-system,system-ui,sans-serif;min-height:100vh;padding:28px}}
.wrap{{max-width:1100px;margin:0 auto}}h1{{font-size:22px;margin:0 0 4px}}h2{{font-size:15px;margin:0 0 14px}}
.sub,.muted{{color:var(--text-secondary)}}.card{{background:var(--surface-1);border:1px solid var(--line);border-radius:12px;padding:18px;margin-top:16px}}
.tiles{{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-top:20px}}
.tile{{background:var(--surface-1);border:1px solid var(--line);border-radius:12px;padding:14px 16px}}
.tl{{color:var(--text-secondary);font-size:12px}}.tv{{font-size:26px;font-weight:600;margin:2px 0}}.ts{{color:var(--muted);font-size:12px}}
.grid2{{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:16px}}.grid2 .card{{margin-top:0}}
ul.tips{{list-style:none;margin:0;padding:0}}ul.tips li{{border-left:3px solid var(--warn);padding:2px 0 2px 12px;margin-bottom:14px}}
ul.tips p{{margin:2px 0 0;color:var(--text-secondary)}}code{{background:var(--line);padding:1px 5px;border-radius:4px;font-size:12px}}
.chart{{width:100%;height:auto}}.grid{{stroke:var(--line)}}.axis{{fill:var(--muted);font-size:11px}}
.legend{{display:flex;gap:16px;flex-wrap:wrap;font-size:12px;color:var(--text-secondary);margin-bottom:6px}}
.legend i{{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;vertical-align:-1px}}
.hrow{{display:grid;grid-template-columns:minmax(90px,38%) 1fr 64px;gap:10px;align-items:center;padding:4px 0}}
.hl{{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--text-secondary)}}
.hb b{{display:block;height:10px;background:var(--s1);border-radius:0 4px 4px 0}}.hv{{text-align:right;font-variant-numeric:tabular-nums}}
table{{width:100%;border-collapse:collapse;font-size:13px}}th,td{{text-align:left;padding:7px 8px;border-bottom:1px solid var(--line)}}
th{{color:var(--text-secondary);font-weight:500}}td.n,th.n{{text-align:right;font-variant-numeric:tabular-nums}}
td.warn{{color:var(--warn);font-weight:600}}.scroll{{overflow-x:auto}}
.hov:hover{{opacity:.85}}#tt{{position:fixed;pointer-events:none;background:var(--text-primary);color:var(--surface-1);
padding:6px 9px;border-radius:6px;font-size:12px;white-space:pre;display:none;z-index:9}}
</style></head><body><div class="viz-root"><div class="wrap">
<h1>Claude Code Usage</h1>
<div class="sub">From local logs in <code>~/.claude/projects</code> · generated {datetime.now():%b %d, %Y %H:%M}</div>
<div class="tiles">{tiles_html}</div>
<div class="card"><h2>Suggestions</h2><ul class="tips">{tips_html}</ul></div>
<div class="card"><h2>Tokens per day</h2>{stacked_days(a['by_day'])}
<p class="muted" style="font-size:12px;margin:6px 0 0">"Cache read" is the big block, but costs only about a tenth of normal input. The expensive parts are mainly "Cache write" and "Output".</p></div>
<div class="grid2" style="margin-top:16px">
<div class="card"><h2>By project</h2>{hbars(projects)}</div>
<div class="card"><h2>By model</h2>{hbars(models)}</div>
<div class="card"><h2>Top tools</h2>{hbars(tools, "×")}</div>
</div>
<div class="card"><h2>Sessions (largest first)</h2><div class="scroll"><table>
<tr><th>Session</th><th>Project</th><th>Start</th><th class=n>Responses</th><th class=n>Peak context</th>
<th class=n>Tokens</th><th class=n>Output</th><th>Model</th><th>Effort</th><th class=n>Cost*</th></tr>
{"".join(srows)}</table></div>
<p class="muted" style="font-size:12px">* Cost as estimated by Claude Code itself (API prices). With a subscription you don't pay this directly. Highlighted: context above {fmt(LONG_CONTEXT)}.</p></div>
</div></div><div id="tt"></div>
<script>
const tt=document.getElementById('tt');
document.querySelectorAll('.hov').forEach(el=>{{
 el.addEventListener('mousemove',e=>{{tt.textContent=el.dataset.tip;tt.style.display='block';
  tt.style.left=Math.min(e.clientX+12,innerWidth-tt.offsetWidth-8)+'px';tt.style.top=(e.clientY+12)+'px'}});
 el.addEventListener('mouseleave',()=>tt.style.display='none')}});
</script></body></html>"""


def main():
    rows, titles, costs, cwds, tools = load()
    a = analyse(rows, titles, costs, cwds, tools)
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(render(a, tips(a)))
    print(f"Analyzed {len(rows)} responses from {len(a['sessions'])} sessions -> {OUT}")


if __name__ == "__main__":
    main()
