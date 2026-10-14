"""Pull requests (gh), their CI/review status and how far a worktree is behind its base."""
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .config import GH, PR_STATUS_TTL, PR_TTL, PR_WATCH_DIR
from .util import git, load_cache, run, save_cache


def fetch_prs(slugs, refresh, offline=False):
    cache = load_cache()
    prs = cache.setdefault("prs", {})
    now = time.time()
    stale = [] if offline else [s for s in slugs if refresh or now - prs.get(s, {}).get("at", 0) > PR_TTL]

    def one(slug):
        code, out, _ = run([GH, "pr", "list", "-R", slug, "--author", "@me", "--state", "all",
                            "--limit", "200", "--json",
                            "number,headRefName,headRefOid,baseRefName,state,url,reviewDecision,isDraft,title"],
                           timeout=60)
        return slug, (json.loads(out) if code == 0 else None)

    if stale:
        with ThreadPoolExecutor(len(stale)) as ex:
            for slug, data in ex.map(one, stale):
                if data is not None:
                    prs[slug] = {"at": now, "items": data}
        save_cache(cache)

    by_branch = {}
    for slug in slugs:
        for pr in prs.get(slug, {}).get("items", []):
            k = (slug, pr["headRefName"])
            prev = by_branch.get(k)
            rank = (pr["state"] == "OPEN", pr["number"])
            if not prev or rank > (prev["state"] == "OPEN", prev["number"]):
                by_branch[k] = pr
    return by_branch


def pr_statuses(worktrees, offline):
    """slug#number → pr_watch.snapshot(): checks, conflicts, review — cached 2 min."""
    if not PR_WATCH_DIR:
        return {}
    sys.path.insert(0, PR_WATCH_DIR)
    try:
        import pr_watch
    except ImportError:
        return {}

    cache = load_cache()
    st = cache.setdefault("pr_status", {})
    now = time.time()
    want = {(w["repo"], w["pr"]["number"]) for w in worktrees if w["pr"] and w["pr"]["state"] == "OPEN"}
    todo = [] if offline else [k for k in want if now - st.get("%s#%d" % k, {}).get("at", 0) > PR_STATUS_TTL]

    def one(key):
        try:
            return key, pr_watch.snapshot(*key)
        except Exception as e:  # gh / network / unknown repo
            return key, {"state": "ERROR", "error": str(e)[:200]}

    if todo:
        with ThreadPoolExecutor(min(6, len(todo))) as ex:
            for key, snap in ex.map(one, todo):
                st["%s#%d" % key] = {"at": now, "snap": snap, "next": pr_watch.NEXT.get(snap.get("state"))}
        save_cache(cache)
    return {k: v for k, v in st.items() if tuple([k.split("#")[0], int(k.split("#")[1])]) in want}


def base_sync(w):
    """Commits behind / ahead of origin/<PR base> using local refs (as of the last fetch)."""
    base = w["pr"]["baseRefName"] if w["pr"] else None
    if not base:
        return None
    code, out, _ = git(w["path"], "rev-list", "--left-right", "--count", "origin/%s...HEAD" % base)
    if code != 0:
        return None
    behind, ahead = (int(x) for x in out.split())
    _, common, _ = git(w["path"], "rev-parse", "--git-common-dir")
    fetch_head = Path(w["path"]) / common.strip() / "FETCH_HEAD"
    try:
        fetched = int(fetch_head.stat().st_mtime)
    except OSError:
        fetched = None
    return {"base": base, "behind": behind, "ahead": ahead, "fetched_ts": fetched}
