"""Command-line interface: argument parsing and the human-readable table."""
import argparse
import json
import os
import signal
import subprocess
import sys
from pathlib import Path

from .cleanup import delete_branch, do_remove, purge_trash
from .config import BACKUPS, CONFIG_PATH, EDITORS, PRUNABLE, WORKSPACE_KEYS, load_config, load_workspaces
from .create import create_worktree
from .model import collect
from .processes import processes_in
from .repos import default_base, find_repo, list_worktrees, main_repos, repos_info
from .sessions import warp_targets
from .util import git, human_age
from .worklog import worklog_today


def find(data, query):
    q = query.lower()
    exact = [w for w in data["worktrees"] if w["name"].lower() == q or w["path"] == query]
    if exact:
        return exact[0]
    hits = [w for w in data["worktrees"] if q in w["name"].lower() or q == (w["ticket"] or "").lower()]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        sys.exit("no worktree matches %r" % query)
    sys.exit("ambiguous %r:\n  " % query + "\n  ".join(w["name"] for w in hits))


def confirm(prompt, yes):
    if yes:
        return True
    try:
        return input(prompt + " [y/N] ").strip().lower() == "y"
    except EOFError:
        print()
        return False


def print_table(data):
    t = data["totals"]
    print("%d worktrees · dependencies/builds %s GB · reclaimable %s GB · disk free %s GB" % (
        t["count"], t["artifacts_gb"], t["reclaimable_gb"], data["disk"]["free_gb"]))
    cur = None
    for w in data["worktrees"]:
        if w["state"] != cur:
            cur = w["state"]
            print("\n" + cur.upper())
        pr = w["pr"]
        nm = w["artifacts"]
        size = "link" if nm["kind"] == "link" else ("-" if nm["kb"] is None else "%.1fG" % (nm["kb"] / 1e6)) if nm["kind"] == "dir" else ""
        print("  %-55s %-5s %-6s %-12s %s" % (
            w["name"][:55], human_age(w["git"].get("activity_ts", 0)), size,
            ("#%d %s" % (pr["number"], pr["state"].lower())) if pr else "",
            "; ".join(w["reasons"])))


def main(usage=None):
    ap = argparse.ArgumentParser(description=usage or __doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list")
    p.add_argument("--json", action="store_true")
    p.add_argument("--sizes", action="store_true", help="compute missing/expired dependency/build dir sizes")
    p.add_argument("--refresh", action="store_true", help="ignore the PR cache")
    p.add_argument("--offline", action="store_true", help="never call gh — PR states from cache, however old")
    p.add_argument("--fresh", action="store_true", help="rescan untracked files instead of using the 60 s cache")
    p = sub.add_parser("open")
    p.add_argument("target")
    p.add_argument("--app", choices=sorted(EDITORS), default="webstorm")
    p = sub.add_parser("procs", help="processes per worktree path (fast; for live polling)")
    p.add_argument("paths", nargs="*")
    p.add_argument("--with-sessions", action="store_true", help="also Claude sessions + Warp tab per worktree")
    p = sub.add_parser("fetch", help="git fetch origin <PR base> for a worktree (updates behind/ahead)")
    p.add_argument("target")
    p = sub.add_parser("config", help="show or change workspaces in ~/.config/git-worktree-tracker/config.json")
    p.add_argument("--workspace", help="workspace to change (default: the first one; created if missing)")
    p.add_argument("--set-bases", nargs="+", metavar="DIR", help="folders scanned for repos")
    p.add_argument("--rename", metavar="NAME", help="rename --workspace")
    p.add_argument("--remove-workspace", metavar="NAME")
    p = sub.add_parser("repos", help="repos with their default and candidate base branches (JSON)")
    p = sub.add_parser("create", help="new worktree on a new branch off a freshly fetched base")
    p.add_argument("repo")
    p.add_argument("branch")
    p.add_argument("--base", help="default: origin/HEAD")
    p.add_argument("--path")
    p.add_argument("--no-deps", action="store_true", help="do not clone node_modules")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("worklog", help="today's worklog via the companion project (JSON)")
    p = sub.add_parser("kill")
    p.add_argument("target")
    p.add_argument("--yes", action="store_true")
    p = sub.add_parser("remove", help="remove one or more worktrees; blocked ones are skipped with the reason")
    p.add_argument("targets", nargs="+")
    p.add_argument("--force", action="store_true",
                   help="also remove worktrees with uncommitted/untracked files or an active /dev run — "
                        "their changes are backed up to ~/Library/Application Support/git-worktree-tracker/backups first")
    p.add_argument("--delete-branch", action="store_true",
                   help="also delete the local branch: -D only when its tip is exactly the merged PR head, else -d")
    p.add_argument("--yes", action="store_true")
    p = sub.add_parser("prune")
    p.add_argument("--yes", action="store_true")
    a = ap.parse_args()

    if a.cmd == "config":
        cfg = load_config()
        if a.set_bases or a.rename or a.remove_workspace:
            if "workspaces" not in cfg:  # migrate a flat config into the first workspace
                flat = {k: cfg.pop(k) for k in WORKSPACE_KEYS if k in cfg}
                flat.setdefault("name", "Default")
                if flat.get("base") and not flat.get("bases"):
                    flat["bases"] = [flat.pop("base")]
                flat.pop("base", None)
                cfg["workspaces"] = [flat] if (flat.get("bases") or len(flat) > 1) else []
            wss = cfg["workspaces"]
            if a.remove_workspace:
                wss[:] = [w for w in wss if w.get("name") != a.remove_workspace]
            name = a.workspace or (wss[0]["name"] if wss else "Default")
            target = next((w for w in wss if w.get("name") == name), None)
            if (a.set_bases or a.rename) and target is None:
                target = {"name": name}
                wss.append(target)
            if a.set_bases:
                target["bases"] = [str(Path(b).expanduser()) for b in a.set_bases]
            if a.rename:
                target["name"] = a.rename
            CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
            tmp = CONFIG_PATH.with_suffix(".tmp")
            tmp.write_text(json.dumps(cfg, indent=2) + "\n")
            os.replace(tmp, CONFIG_PATH)
        shown = load_workspaces(load_config())
        print(json.dumps({"path": str(CONFIG_PATH), "workspaces": [
            {"name": w["name"], "bases": w["bases"], "configured": w["configured"]} for w in shown]}, indent=2))
        return

    if a.cmd == "repos":
        json.dump(repos_info(), sys.stdout)
        return

    if a.cmd == "create":
        repo = find_repo(a.repo)
        res = create_worktree(repo, a.branch, a.base or default_base(repo), a.path, not a.no_deps)
        if a.json:
            json.dump(res, sys.stdout)
        else:
            print("\n".join(res.get("steps", [])) + ("\n" + res["error"] if not res["ok"] else ""))
        sys.exit(0 if res["ok"] else 1)

    if a.cmd == "worklog":
        json.dump(worklog_today(), sys.stdout)
        return

    if a.cmd == "procs":
        paths = [p for p in (a.paths or [i["worktree"] for r in main_repos() for i in list_worktrees(r)]) if Path(p).is_dir()]
        procs = processes_in(paths)
        if a.with_sessions:
            json.dump({"procs": procs, "targets": warp_targets(paths, procs)}, sys.stdout)
        else:
            json.dump(procs, sys.stdout)
        return

    if a.cmd == "list":
        data = collect(sizes=a.sizes, refresh=a.refresh, offline=a.offline, fresh_untracked=a.fresh)
        if a.json:
            json.dump(data, sys.stdout)
        else:
            print_table(data)
        return

    targets = getattr(a, "targets", None) or ([a.target] if getattr(a, "target", None) else None)
    data = collect(offline=a.cmd != "prune", fresh_untracked=a.cmd in ("remove", "prune"), only=targets)
    if a.cmd == "fetch":
        w = find(data, a.target)
        base = (w.get("base_sync") or {}).get("base") or (w["pr"] or {}).get("baseRefName")
        if not base:
            sys.exit("no PR base known for %s" % w["name"])
        code, _, err = git(w["repo_path"], "fetch", "origin", base, "--prune")
        print("fetched origin/%s" % base if code == 0 else "fetch failed: " + err.strip())
        sys.exit(code)

    if a.cmd == "open":
        w = find(data, a.target)
        cmd = ["open", w["path"]] if a.app == "finder" else ["open", "-a", EDITORS[a.app], w["path"]]
        sys.exit(subprocess.call(cmd))

    if a.cmd == "kill":
        w = find(data, a.target)
        if not w["procs"]:
            print("nothing running in", w["name"])
            return
        for p in w["procs"]:
            print("  %6d %-8s %s" % (p["pid"], p.get("etime", ""), p.get("cmd", p["name"])))
        if confirm("SIGTERM these %d process(es)?" % len(w["procs"]), a.yes):
            for p in w["procs"]:
                try:
                    os.kill(p["pid"], signal.SIGTERM)
                except ProcessLookupError:
                    pass
            print("sent SIGTERM")
        return

    if a.cmd == "remove":
        picked = list({w["path"]: w for w in (find(data, t) for t in a.targets)}.values())
        key = "force_blockers" if a.force else "remove_blockers"
        ok_list = [w for w in picked if not w[key]]
        problems = ["%s — skipped: %s" % (w["name"], "; ".join(w[key])) for w in picked if w[key]]
        forced = [w for w in ok_list if w["remove_blockers"]]
        prompt = "remove %d worktree(s)? branches are kept\n  %s" % (len(ok_list), "\n  ".join(w["path"] for w in ok_list))
        if forced:
            prompt += "\nFORCE: %d have local changes — backed up to %s, then deleted" % (len(forced), BACKUPS)
        if ok_list and confirm(prompt, a.yes):
            for w in ok_list:
                ok, err = do_remove(w, force=a.force and bool(w["remove_blockers"]))
                print(("removed " if ok else "FAILED  ") + w["name"]
                      + ("  · backup " + w["backup"] if w.get("backup") else ""))
                if not ok:
                    problems.append("%s — git refused: %s" % (w["name"], err))
                elif a.delete_branch and w["branch"]:
                    msg = delete_branch(w)
                    if msg:
                        problems.append("%s — branch kept: %s" % (w["name"], msg))
            purge_trash()
        if problems:
            sys.exit("\n".join(problems))
        return

    if a.cmd == "prune":
        cands = [w for w in data["worktrees"] if w["removable"] and w["state"] in PRUNABLE]
        if not cands:
            print("nothing to prune")
            return
        for w in cands:
            print("  %-60s %s" % (w["name"], "; ".join(w["reasons"])))
        if confirm("remove these %d worktree(s)? branches are kept" % len(cands), a.yes):
            for w in cands:
                ok, err = do_remove(w)
                print(("  removed " if ok else "  FAILED  ") + w["name"] + ("" if ok else " — " + err))
            purge_trash()
