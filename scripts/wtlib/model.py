"""Assembles the full picture of every worktree: state, reasons, removal blockers."""
import re
import shutil
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .artifacts import artifact_sizes, ecosystems
from .config import ACTIVE_DAYS, BASES, CONFIGURED, FORCE_MIN_IDLE_H, PRUNABLE, STALE_DAYS, STATE_ORDER, UNTRACKED_TTL, WORKSPACES
from .gitstate import git_state
from .processes import processes_in
from .prs import base_sync, fetch_prs, pr_statuses
from .repos import list_worktrees, main_repos, repo_slug
from .runs import dev_runs
from .sessions import warp_targets
from .util import git, load_cache, run, save_cache


def classify(w, now):
    reasons = []
    if w["missing"]:
        return "missing", ["directory is gone — `git worktree prune` cleans it"]
    pr, runinfo = w["pr"], w["run"]
    dirty = w["git"]["modified"] + w["git"]["untracked"]
    age_days = (now - w["git"].get("activity_ts", 0)) / 86400
    if dirty:
        reasons.append("%d uncommitted file(s)" % dirty)
    if w["procs"]:
        reasons.append("%d process(es) running" % len(w["procs"]))
    if runinfo and runinfo.get("status") == "active":
        reasons.append("/dev run active @ " + runinfo.get("stage", "?"))
    if pr and pr["state"] == "MERGED" and not dirty:
        return "merged", reasons or ["PR #%d merged" % pr["number"]]
    if pr and pr["state"] == "CLOSED" and not dirty:
        return "closed", reasons or ["PR #%d closed" % pr["number"]]
    if w["procs"] or (runinfo or {}).get("status") == "active" or age_days <= ACTIVE_DAYS:
        return "active", reasons + ([] if reasons else ["touched %dh ago" % (age_days * 24)])
    if pr and pr["state"] == "OPEN":
        decision = (pr.get("reviewDecision") or "").lower().replace("_", " ")
        return "review", reasons + ["PR #%d open%s" % (pr["number"], " · " + decision if decision else "")]
    if age_days > STALE_DAYS:
        return "stale", reasons + ["untouched %d days" % age_days]
    return "idle", reasons + ["untouched %d days" % age_days]


def removal_blockers(w):
    if w["missing"]:
        return []
    b = []
    g = w["git"]
    if w.get("locked"):
        b.append("worktree is locked")
    if g.get("error"):
        b.append(g["error"])
    if g["modified"]:
        b.append("%d modified file(s)" % g["modified"])
    if g["untracked"]:
        b.append("%d untracked file(s)" % g["untracked"])
    pr = w["pr"]
    head_in_merged_pr = pr and pr["state"] == "MERGED" and w["head"] == pr.get("headRefOid")
    if g.get("unpushed") and not head_in_merged_pr:
        b.append("%d commit(s) on no remote branch" % g["unpushed"])
    if w["procs"]:
        b.append("%d process(es) running inside" % len(w["procs"]))
    if w["run"] and w["run"].get("status") == "active":
        b.append("/dev run still active (%s)" % w["run"].get("stage"))
    return b


def force_blockers(w):
    """What still blocks `remove --force`: things the pre-removal backup cannot preserve.
    Dirty files are backed up, unpushed commits on a branch survive because the branch is kept."""
    if w["missing"]:
        return []
    b = []
    if w.get("locked"):
        b.append("worktree is locked")
    if w["git"].get("error"):
        b.append(w["git"]["error"])
    if w["procs"]:
        b.append("%d process(es) running inside — stop them first" % len(w["procs"]))
    if not w["branch"] and w["git"].get("unpushed"):
        b.append("detached HEAD with %d commit(s) on no branch" % w["git"]["unpushed"])
    age_h = (time.time() - w["git"].get("activity_ts", 0)) / 3600
    if (w["git"]["modified"] or w["git"]["untracked"]) and age_h < FORCE_MIN_IDLE_H:
        b.append("changed %dh ago — still in use" % age_h)
    return b


def collect(sizes=False, refresh=False, offline=False, fresh_untracked=False, only=None):
    now = time.time()
    raw = []
    for repo in main_repos():
        slug = repo_slug(repo)
        for item in list_worktrees(repo):
            path = item["worktree"]
            branch = item.get("branch")
            raw.append({
                "name": Path(path).name,
                "path": path,
                "repo": repo.name,
                "repo_path": str(repo),
                "repo_kind": repo.kind,
                "workspace": repo.workspace,
                "slug": slug,
                "branch": branch[len("refs/heads/"):] if isinstance(branch, str) else None,
                "head": item.get("HEAD"),
                "locked": bool(item.get("locked")),
                "missing": not Path(path).is_dir() or bool(item.get("prunable")),
            })

    if only:
        keep = []
        for target in only:
            q = target.lower()
            exact = [w for w in raw if w["path"] == target or w["name"].lower() == q]
            keep += exact or [w for w in raw if q in w["name"].lower() or q in (w["branch"] or "").lower()]
        raw = list({w["path"]: w for w in keep}.values())

    live = [w["path"] for w in raw if not w["missing"]]
    cache = load_cache()
    ucache = cache.setdefault("untracked", {})

    def reuse(p):
        hit = ucache.get(p)
        if fresh_untracked or not hit:
            return None
        return hit["files"] if offline or now - hit["at"] < UNTRACKED_TTL else None

    with ThreadPoolExecutor(8) as ex:
        states = dict(zip(live, ex.map(lambda p: git_state(p, reuse(p)), live)))
    for p, st in states.items():
        if "_untracked" in st:
            ucache[p] = {"files": st.pop("_untracked")[:200], "at": now}
    for p in [p for p in ucache if p not in states and not only]:
        del ucache[p]
    save_cache(cache)
    prs = fetch_prs(sorted({w["slug"] for w in raw if w["slug"]}), refresh, offline)
    nm = artifact_sizes(live, sizes)
    procs = processes_in(live)
    runs = dev_runs()

    out = []
    for w in raw:
        ticket_re = next((ws["ticket_re"] for ws in WORKSPACES if ws["name"] == w["workspace"]), WORKSPACES[0]["ticket_re"])
        m = ticket_re.search(w["branch"] or "") or ticket_re.search(w["name"])
        ticket = m.group(0).upper() if m else None
        run_ = runs.get(ticket) if ticket else None
        if run_ and run_.get("repo") not in (None, "", w["repo"]):
            run_ = None
        run_branch = (run_ or {}).get("branch") or ""
        if run_ and w["branch"] and re.match(r"[\w.]+/", run_branch) and w["branch"] not in run_branch:
            run_ = None
        w.update(
            ticket=ticket,
            git=states.get(w["path"], {"modified": 0, "untracked": 0}),
            pr=prs.get((w["slug"], w["branch"])),
            run={k: run_.get(k) for k in ("stage", "status", "next_action", "updated")} if run_ else None,
            artifacts=nm.get(w["path"], {"kind": "none", "kb": 0, "items": []}),
            ecosystems=ecosystems(w["path"]) if not w["missing"] else [],
            procs=procs.get(w["path"], []),
        )
        w["state"], w["reasons"] = classify(w, now)
        w["remove_blockers"] = removal_blockers(w)
        w["removable"] = not w["remove_blockers"]
        w["force_blockers"] = force_blockers(w)
        w["base_sync"] = base_sync(w) if w["pr"] and w["pr"]["state"] == "OPEN" and not w["missing"] else None
        out.append(w)

    statuses = pr_statuses(out, offline) if not only else {}
    targets = warp_targets(live, procs) if not only else {}
    for w in out:
        ps = statuses.get("%s#%d" % (w["repo"], w["pr"]["number"])) if w["pr"] else None
        w["pr_status"] = dict(ps["snap"], next=ps["next"], at=int(ps["at"])) if ps else None
        t = targets.get(w["path"], {})
        w["sessions"] = t.get("sessions", [])
        w["warp"] = t.get("warp")
    out.sort(key=lambda w: (STATE_ORDER.index(w["state"]), -w["git"].get("activity_ts", 0)))
    du = shutil.disk_usage(str(Path.home()))
    nm_kb = sum(w["artifacts"]["kb"] or 0 for w in out)
    reclaim_kb = sum(w["artifacts"]["kb"] or 0 for w in out
                     if w["removable"] and w["state"] in PRUNABLE)
    return {
        "generated_at": int(now),
        "bases": BASES,
        "configured": CONFIGURED,
        "disk": {"free_gb": round(du.free / 1e9, 1), "total_gb": round(du.total / 1e9, 1)},
        "totals": {
            "count": len(out),
            "by_state": {s: sum(1 for w in out if w["state"] == s) for s in STATE_ORDER},
            "artifacts_gb": round(nm_kb / 1e6, 1),
            "reclaimable_gb": round(reclaim_kb / 1e6, 1),
            "sizes_complete": all(w["artifacts"]["kb"] is not None for w in out),
        },
        "worktrees": out,
        "workspaces": [{"name": w["name"], "bases": w["bases"], "jira_url": w["jira_url"],
                        "configured": w["configured"]} for w in WORKSPACES],
        "config": {"jira_url": WORKSPACES[0]["jira_url"],
                   "repos": {k: v for w in reversed(WORKSPACES) for k, v in w["repos"].items()}},
    }
