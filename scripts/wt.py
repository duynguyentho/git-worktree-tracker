#!/usr/bin/env python3
"""git-worktree-tracker — backend + CLI of the Worktrees macOS app.

    python3 scripts/wt.py list [--json] [--sizes] [--refresh]
    python3 scripts/wt.py open <name|KEY> [--app webstorm|code|cursor|warp|finder]
    python3 scripts/wt.py kill <name|KEY> [--yes]
    python3 scripts/wt.py remove <name|KEY> [--yes]
    python3 scripts/wt.py prune [--yes]

Sources: `git worktree list` of every repo found under the configured folders, `gh pr list` (cached),
`.claude/memory/dev-runs.json`, `lsof` (processes whose cwd is inside a worktree).
Removal is `git worktree remove` without --force, and only when nothing can be lost.
"""
import argparse
import ctypes
import ctypes.util
import json
import os
import re
import shutil
import signal
import sqlite3
import struct
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
CONFIG_PATH = Path(os.environ.get("WT_CONFIG", "~/.config/git-worktree-tracker/config.json")).expanduser()


def load_config():
    try:
        return json.loads(CONFIG_PATH.read_text())
    except (OSError, ValueError):
        return {}


CONFIG = load_config()
# A workspace = a named set of folders plus its own Jira URL, ticket pattern, repo labels and
# companion project. Legacy flat configs (top-level "bases"/"base") read as one workspace.
# Unconfigured → whichever common code folders exist (never ~/Documents, which would trigger a
# macOS privacy prompt before the user picked anything).
DEFAULT_CANDIDATES = ["~/Projects", "~/Developer", "~/code", "~/Code", "~/src", "~/dev", "~/work",
                      "~/repos", "~/git", "~/GitHub", "~/workspace"]
WORKSPACE_KEYS = ("name", "bases", "base", "jira_url", "ticket_regex", "repos", "assistant", "scan_depth")
DEFAULT_TICKET_RE = r"\b[A-Z][A-Z0-9]+-\d+\b"


def _norm_workspace(ws, configured):
    bases = ws.get("bases") or ([ws["base"]] if ws.get("base") else [])
    assistant = os.environ.get("WT_ASSISTANT") or ws.get("assistant")
    assistant = Path(assistant).expanduser() if assistant else None
    return {
        "name": ws.get("name") or "Default",
        "bases": list(dict.fromkeys(str(Path(b).expanduser()) for b in bases)),
        "jira_url": ws.get("jira_url"),
        "ticket_re": re.compile(ws.get("ticket_regex") or DEFAULT_TICKET_RE),
        "repos": ws.get("repos") or {},
        "assistant": assistant,
        "dev_runs": os.environ.get("WT_DEV_RUNS") or (assistant and assistant / ".claude" / "memory" / "dev-runs.json"),
        "scan_depth": int(ws.get("scan_depth") or CONFIG.get("scan_depth") or 3),
        "configured": configured,
    }


def load_workspaces(cfg):
    if os.environ.get("WT_BASE"):
        flat = {k: cfg[k] for k in WORKSPACE_KEYS if k in cfg}
        return [_norm_workspace(dict(flat, bases=[os.environ["WT_BASE"]]), True)]
    if cfg.get("workspaces"):
        return [_norm_workspace(w, True) for w in cfg["workspaces"]]
    flat = {k: cfg[k] for k in WORKSPACE_KEYS if k in cfg}
    if flat.get("bases") or flat.get("base"):
        return [_norm_workspace(flat, True)]
    found = [c for c in DEFAULT_CANDIDATES if Path(c).expanduser().is_dir()]
    return [_norm_workspace(dict(flat, bases=found), False)]


WORKSPACES = load_workspaces(CONFIG)
CONFIGURED = any(w["configured"] for w in WORKSPACES)
BASES = list(dict.fromkeys(b for w in WORKSPACES for b in w["bases"]))
SCAN_SKIP = {"node_modules", "vendor", "Library", "Applications", ".Trash", "target", "dist", "build"}
STATE_HOME = Path("~/Library/Application Support/git-worktree-tracker").expanduser()
CACHE_PATH = Path(os.environ.get("WT_CACHE_PATH") or "~/Library/Caches/git-worktree-tracker/wt_cache.json").expanduser()
PR_WATCH_DIR = os.environ.get("WT_PR_WATCH_DIR") or next(
    (str(w["assistant"] / "scripts") for w in WORKSPACES if w["assistant"]), None)
GH = os.environ.get("GH_BIN") or shutil.which("gh") or "/opt/homebrew/bin/gh"

PR_TTL = 10 * 60
SIZE_TTL = 12 * 3600
UNTRACKED_TTL = 60
ACTIVE_DAYS = 2
STALE_DAYS = 14
FORCE_MIN_IDLE_H = 24
EDITORS = {
    "webstorm": "WebStorm",
    "code": "Visual Studio Code",
    "cursor": "Cursor",
    "warp": "Warp",
    "finder": "Finder",
}


def run(cmd, cwd=None, timeout=60):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", PATH=os.environ.get("PATH", "") + ":/opt/homebrew/bin:/usr/local/bin")
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)
    return p.returncode, p.stdout, p.stderr


def git(path, *args):
    return run(["git", "--no-optional-locks", "-C", str(path), *args])


# ---------------------------------------------------------------- cache

def load_cache():
    try:
        return json.loads(CACHE_PATH.read_text())
    except (OSError, ValueError):
        return {}


def save_cache(cache):
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = CACHE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(cache))
    os.replace(tmp, CACHE_PATH)


# ---------------------------------------------------------------- discovery

class Repo:
    """A repository found on disk. `path` is what git commands run against: the checkout of a
    normal repo, or the git dir itself for a bare one."""

    def __init__(self, path, kind, workspace):
        self.path, self.kind, self.workspace = Path(path), kind, workspace
        n = self.path.name
        if kind == "bare":
            n = self.path.parent.name if n in (".bare", ".git") else (n[:-4] if n.endswith(".git") else n)
        self.name = n

    def __str__(self):
        return str(self.path)


def _common_dir_of_gitfile(d):
    """`.git` FILE (a linked worktree, or the `.bare` layout's main folder) → the shared git dir."""
    try:
        line = (d / ".git").read_text().strip()
    except OSError:
        return None
    if not line.startswith("gitdir:"):
        return None
    gitdir = Path(line[7:].strip())
    gitdir = (d / gitdir).resolve() if not gitdir.is_absolute() else gitdir.resolve()
    try:
        return (gitdir / (gitdir / "commondir").read_text().strip()).resolve()
    except OSError:
        return gitdir


def _repo_from_common(common, workspace):
    common = Path(common)
    if common.name == ".git" and (common.parent / ".git").is_dir():
        return Repo(common.parent, "normal", workspace)
    if (common / "HEAD").is_file() and (common / "objects").is_dir():
        return Repo(common, "bare", workspace)
    return None


def _looks_bare(d):
    return (d / "HEAD").is_file() and (d / "objects").is_dir() and (d / "refs").is_dir() and not (d / ".git").exists()


def main_repos():
    """Every repo under every workspace's folders, up to its scan depth:
    - a normal checkout (`.git` directory),
    - a bare repo (`repo.git/`, `.bare/` …), the usual home of worktree-heavy setups,
    - and, through any linked worktree met on the way (`.git` file), the repo it belongs to —
      even when that repo lives outside the configured folders.
    A repo's own subfolders are not searched."""
    found = {}

    def add(repo):
        if repo:
            found.setdefault(os.path.realpath(repo.path), repo)

    def inspect(d, ws):
        """True when `d` is a repo or a worktree (stop descending)."""
        g = d / ".git"
        if g.is_dir():
            add(Repo(d, "normal", ws["name"]))
            return True
        if g.is_file():
            common = _common_dir_of_gitfile(d)
            if common:
                add(_repo_from_common(common, ws["name"]))
            return True
        if _looks_bare(d):
            add(Repo(d, "bare", ws["name"]))
            return True
        return False

    def walk(d, depth, ws):
        try:
            entries = sorted(e for e in d.iterdir() if e.is_dir() and not e.is_symlink())
        except OSError:
            return
        for e in entries:
            if e.name in SCAN_SKIP or (e.name.startswith(".") and e.name != ".bare"):
                continue
            if not inspect(e, ws) and depth > 1:
                walk(e, depth - 1, ws)

    for ws in WORKSPACES:
        for base in ws["bases"]:
            b = Path(base)
            if b.is_dir() and not inspect(b, ws):
                walk(b, ws["scan_depth"], ws)
    return list(found.values())


def repo_slug(repo):
    _, out, _ = git(repo, "remote", "get-url", "origin")
    m = re.search(r"github\.com[:/](.+?)(?:\.git)?$", out.strip())
    return m.group(1) if m else None


def list_worktrees(repo):
    _, out, _ = git(repo, "worktree", "list", "--porcelain")
    items, cur = [], {}
    for line in out.splitlines() + [""]:
        if not line:
            if cur:
                items.append(cur)
            cur = {}
            continue
        key, _, val = line.partition(" ")
        cur[key] = val or True
    main = os.path.realpath(str(repo))
    return [i for i in items if not i.get("bare") and os.path.realpath(i.get("worktree", "")) != main]


# ---------------------------------------------------------------- per-source data

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


ARTIFACT_DIRS = CONFIG.get("artifact_dirs") or [
    "node_modules", ".next", ".nuxt", ".turbo", "dist",          # JS / TS
    ".venv", "venv", ".tox", ".mypy_cache", ".pytest_cache",     # Python
    "vendor",                                                    # Go / PHP (only when git-ignored)
    "target", "build", ".gradle",                                # Rust / JVM
    ".build", "Pods", "DerivedData",                             # Swift / iOS
]
ECOSYSTEM_MARKERS = [
    ("go.mod", "go"), ("pyproject.toml", "python"), ("requirements.txt", "python"), ("setup.py", "python"),
    ("Pipfile", "python"), ("package.json", "node"), ("Cargo.toml", "rust"), ("pom.xml", "java"),
    ("build.gradle", "java"), ("build.gradle.kts", "kotlin"), ("Package.swift", "swift"), ("Gemfile", "ruby"),
    ("composer.json", "php"), ("mix.exs", "elixir"), ("main.tf", "terraform"),
]


def ecosystems(path):
    seen = []
    for marker, eco in ECOSYSTEM_MARKERS:
        if eco not in seen and (Path(path) / marker).exists():
            seen.append(eco)
    return seen


def ignored_artifacts(path):
    """Top-level dependency/build dirs that exist AND git ignores — a tracked dir (a committed Go
    `vendor/`) is never counted or touched."""
    present = [d for d in ARTIFACT_DIRS if (Path(path) / d).is_dir() or (Path(path) / d).is_symlink()]
    if not present:
        return []
    p = subprocess.run(["git", "--no-optional-locks", "-C", str(path), "check-ignore", "--stdin"],
                       input="\n".join(present), capture_output=True, text=True)
    ignored = set(p.stdout.split())
    return [d for d in present if d in ignored]


def artifact_sizes(paths, compute):
    """path → {"kind": dir|link|none, "kb": total or None while unmeasured, "items": [{name, kind, kb}]}."""
    cache = load_cache()
    sizes = cache.setdefault("sizes", {})
    now = time.time()
    result, todo = {}, []
    with ThreadPoolExecutor(8) as ex:
        found = dict(zip(paths, ex.map(ignored_artifacts, paths)))
    for p in paths:
        items = []
        for name in found[p]:
            d = Path(p) / name
            if d.is_symlink():
                items.append({"name": name, "kind": "link", "kb": 0})
                continue
            key = "%s::%s" % (p, name)
            hit = sizes.get(key)
            item = {"name": name, "kind": "dir", "kb": hit["kb"] if hit else None}
            if not hit or now - hit["at"] >= SIZE_TTL:
                todo.append((p, name, item))
            items.append(item)
        result[p] = items
    if compute and todo:
        def du(job):
            p, name, item = job
            code, out, _ = run(["du", "-sk", str(Path(p) / name)], timeout=300)
            return job, int(out.split()[0]) if code == 0 and out else None

        with ThreadPoolExecutor(6) as ex:
            for (p, name, item), kb in ex.map(du, todo):
                if kb is not None:
                    sizes["%s::%s" % (p, name)] = {"kb": kb, "at": now}
                    item["kb"] = kb
        save_cache(cache)
    out = {}
    for p, items in result.items():
        dirs = [i for i in items if i["kind"] == "dir"]
        kind = "dir" if dirs else ("link" if items else "none")
        total = None if any(i["kb"] is None for i in dirs) else sum(i["kb"] for i in dirs)
        out[p] = {"kind": kind, "kb": total, "items": items}
    return out


def processes_in(paths):
    """root → [proc] for every process whose cwd is inside a worktree, plus all their descendants
    (jest workers, ts-node children…). Each proc carries rss_kb / cpu (ps %CPU, a decaying average)."""
    _, out, _ = run(["lsof", "-nP", "-d", "cwd", "-Fpcn"], timeout=30)
    procs, pid, cmd = {}, None, None
    roots = sorted((str(p) for p in paths), key=len, reverse=True)
    for line in out.splitlines():
        tag, val = line[:1], line[1:]
        if tag == "p":
            pid = int(val)
        elif tag == "c":
            cmd = val
        elif tag == "n" and pid:
            for root in roots:
                if val == root or val.startswith(root + "/"):
                    procs[pid] = {"pid": pid, "name": cmd, "root": root, "ports": [], "child": False}
                    break
    if not procs:
        return {}

    _, out, _ = run(["ps", "-axo", "pid=,ppid=,rss=,%cpu=,etime=,comm=,command="])
    table, children = {}, {}
    for line in out.splitlines():
        parts = line.split(None, 6)
        if len(parts) < 7:
            continue
        p_, pp = int(parts[0]), int(parts[1])
        table[p_] = {"rss_kb": int(parts[2]), "cpu": float(parts[3]), "etime": parts[4],
                     "comm": os.path.basename(parts[5]), "cmd": parts[6][:200]}
        children.setdefault(pp, []).append(p_)
    stack = list(procs)
    while stack:
        parent = stack.pop()
        for c in children.get(parent, []):
            if c not in procs and c in table:
                procs[c] = {"pid": c, "name": table[c]["comm"], "root": procs[parent]["root"],
                            "ports": [], "child": True, "ppid": parent}
                stack.append(c)
    for p_, info in procs.items():
        t = table.get(p_)
        if t:
            info.update(rss_kb=t["rss_kb"], cpu=t["cpu"], etime=t["etime"], cmd=t["cmd"])

    pids = ",".join(str(p) for p in procs)
    _, out, _ = run(["lsof", "-nP", "-a", "-p", pids, "-iTCP", "-sTCP:LISTEN", "-Fpn"], timeout=30)
    pid = None
    for line in out.splitlines():
        if line[:1] == "p":
            pid = int(line[1:])
        elif line[:1] == "n" and pid in procs:
            port = line.rsplit(":", 1)[-1]
            if port not in procs[pid]["ports"]:
                procs[pid]["ports"].append(port)
    by_root = {}
    for p in sorted(procs.values(), key=lambda p: -p.get("rss_kb", 0)):
        by_root.setdefault(p.pop("root"), []).append(p)
    return by_root


def dev_runs():
    """ticket → /dev run, merged across every workspace's companion project."""
    runs = {}
    for path in dict.fromkeys(str(w["dev_runs"]) for w in WORKSPACES if w["dev_runs"]):
        try:
            items = json.loads(Path(path).read_text()).get("runs", [])
        except (OSError, ValueError):
            continue
        for r in items:
            runs.setdefault((r.get("ticket") or "").upper(), r)
    return runs


# ---------------------------------------------------------------- per-worktree git

def git_state(path, cached_untracked=None):
    """Untracked scan dominates (≈0.4s on a 25k-file repo) — reuse `cached_untracked` when given."""
    info = {"modified": 0, "untracked": 0, "ahead": 0, "behind": 0, "upstream": None}
    scan = "-uno" if cached_untracked is not None else "-unormal"
    code, out, _ = git(path, "status", "--porcelain=v1", "-b", scan)
    if code != 0:
        info["error"] = "git status failed"
        return info
    dirty_files = list(cached_untracked or [])
    info["untracked"] = len(dirty_files)
    files = [{"s": "??", "p": f} for f in dirty_files]
    for line in out.splitlines():
        if line.startswith("## "):
            m = re.search(r"\.\.\.(\S+)", line)
            info["upstream"] = m.group(1) if m else None
            for k in ("ahead", "behind"):
                m = re.search(k + r" (\d+)", line)
                info[k] = int(m.group(1)) if m else 0
        elif line.startswith("??"):
            info["untracked"] += 1
            dirty_files.append(line[3:])
            info.setdefault("_untracked", []).append(line[3:])
            files.append({"s": "??", "p": line[3:]})
        else:
            info["modified"] += 1
            dirty_files.append(line[3:].split(" -> ")[-1])
            files.append({"s": line[:2].strip() or "M", "p": line[3:]})
    info["files"] = files[:100]
    _, out, _ = git(path, "log", "-1", "--format=%h%x00%ct%x00%s")
    parts = out.strip().split("\x00")
    if len(parts) == 3:
        info["last_commit"] = {"sha": parts[0], "ts": int(parts[1]), "subject": parts[2][:120]}
    _, out, _ = git(path, "rev-list", "--count", "HEAD", "--not", "--remotes")
    info["unpushed"] = int(out.strip() or 0)

    stamps = [info.get("last_commit", {}).get("ts", 0)]
    _, gitdir, _ = git(path, "rev-parse", "--absolute-git-dir")
    for f in ("index", "HEAD"):
        try:
            stamps.append(int((Path(gitdir.strip()) / f).stat().st_mtime))
        except OSError:
            pass
    for f in dirty_files[:50]:
        try:
            stamps.append(int((Path(path) / f.strip('"')).stat().st_mtime))
        except OSError:
            pass
    info["activity_ts"] = max(stamps)
    if cached_untracked is None:
        info["_untracked"] = info.get("_untracked", [])
    return info


# ---------------------------------------------------------------- assemble

STATE_ORDER = ["active", "review", "idle", "stale", "merged", "closed", "missing"]
PRUNABLE = ("merged", "closed", "missing")


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


# ---------------------------------------------------------------- Claude sessions & Warp tabs

CLAUDE_HOME = Path.home() / ".claude"
WARP_DB = (Path.home() / "Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support"
           / "dev.warp.Warp-Stable/warp.sqlite")
SESSION_LOOKBACK_S = 8 * 3600
_libc = ctypes.CDLL(ctypes.util.find_library("c"))


def warp_uuid_of(pid):
    """WARP_TERMINAL_SESSION_UUID from a process's environment (KERN_PROCARGS2, same-user only).
    Every process started from a Warp pane inherits it; `warp://session/<uuid>` focuses that pane."""
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t(0)
    if _libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or not size.value:
        return None
    buf = ctypes.create_string_buffer(size.value)
    if _libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        return None
    for part in buf.raw[4:size.value].split(b"\0"):
        if part.startswith(b"WARP_TERMINAL_SESSION_UUID="):
            return part.split(b"=", 1)[1].decode()
    return None


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def claude_sessions(paths):
    """path → Claude Code sessions whose recent tool calls touched that worktree, newest first.
    Source: ~/.claude/sessions/<pid>.json (live sessions) + the tail of each session transcript."""
    roots = sorted(paths, key=len, reverse=True)
    out = {}
    cutoff = time.time() - SESSION_LOOKBACK_S
    for f in (CLAUDE_HOME / "sessions").glob("*.json"):
        try:
            s = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        pid = s.get("pid")
        if not pid or not alive(pid):
            continue
        tr = CLAUDE_HOME / "projects" / re.sub(r"[^A-Za-z0-9]", "-", s.get("cwd", "")) / (s.get("sessionId", "") + ".jsonl")
        last = {}
        try:
            with open(tr, "rb") as fh:
                fh.seek(max(0, tr.stat().st_size - 400_000))
                lines = fh.read().splitlines()[1:]
        except OSError:
            continue
        for line in lines:
            if b'"tool_use"' not in line and b'"cwd"' not in line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            ts = obj.get("timestamp")
            hay = []
            cwd = obj.get("cwd")
            if cwd:
                hay.append(cwd + "/")
            for item in (obj.get("message") or {}).get("content") or []:
                if isinstance(item, dict) and item.get("type") == "tool_use":
                    hay.append(json.dumps(item.get("input")))
            text = "\n".join(hay)
            for root in roots:
                if root + "/" in text or root + '"' in text or root + " " in text:
                    last[root] = ts
        for root, ts in last.items():
            try:
                epoch = time.mktime(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone if ts else 0
            except ValueError:
                epoch = 0
            if epoch and epoch < cutoff:
                continue
            out.setdefault(root, []).append({
                "pid": pid, "name": s.get("name"), "status": s.get("status"), "session_id": s.get("sessionId"),
                "warp": warp_uuid_of(pid), "last_ts": int(epoch)})
    for v in out.values():
        v.sort(key=lambda x: -x["last_ts"])
    return out


def warp_panes(paths):
    """path → Warp pane uuids whose saved cwd is inside it (Warp's own session DB, read-only)."""
    if not WARP_DB.exists():
        return {}
    roots = sorted(paths, key=len, reverse=True)
    try:
        con = sqlite3.connect("file:%s?mode=ro" % WARP_DB, uri=True, timeout=1)
        rows = con.execute("SELECT lower(hex(uuid)), cwd FROM terminal_panes WHERE cwd IS NOT NULL").fetchall()
        con.close()
    except sqlite3.Error:
        return {}
    out = {}
    for uuid, cwd in rows:
        root = next((r for r in roots if cwd == r or cwd.startswith(r + "/")), None)
        if root:
            out.setdefault(root, []).append(uuid)
    return out


def warp_targets(paths, procs):
    """Best Warp pane to jump to per worktree: the Claude session working on it, else a pane whose
    process runs inside it, else a pane whose shell cwd is inside it."""
    sessions = claude_sessions(paths)
    panes = warp_panes(paths)
    out = {}
    for path in paths:
        target = None
        for s in sessions.get(path, []):
            if s["warp"]:
                target = {"uuid": s["warp"], "source": "claude", "label": s["name"]}
                break
        if not target:
            for p in procs.get(path, []):
                if not p.get("child"):
                    u = warp_uuid_of(p["pid"])
                    if u:
                        target = {"uuid": u, "source": "process", "label": p.get("name")}
                        break
        if not target and panes.get(path):
            target = {"uuid": panes[path][0], "source": "pane", "label": "shell"}
        out[path] = {"sessions": sessions.get(path, []), "warp": target}
    return out


# ---------------------------------------------------------------- PR / CI status (open PRs only)

PR_STATUS_TTL = 120


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


# ---------------------------------------------------------------- create a worktree

LOCKFILES = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock"]
CLONABLE_DEPS = ["node_modules"]  # relocatable as-is; a .venv bakes absolute paths in, so never cloned


def find_repo(query):
    q = query.lower()
    repos = main_repos()
    exact = [r for r in repos if str(r.path) == query or r.name.lower() == q]
    if exact:
        return exact[0]
    hits = [r for r in repos if q in r.name.lower()]
    if len(hits) == 1:
        return hits[0]
    sys.exit("no single repo matches %r (%s)" % (query, ", ".join(r.name for r in hits) or "none"))


def default_base(repo):
    code, out, _ = git(repo.path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    return out.strip().split("/", 1)[1] if code == 0 and "/" in out else "main"


def repos_info():
    out = []
    for r in main_repos():
        _, refs, _ = git(r.path, "for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/remotes/origin")
        bases = [x.split("/", 1)[1] for x in refs.split() if "/" in x and not x.endswith("/HEAD")]
        primary = [b for b in bases if re.match(r"(develop|main|master|release|releasing|staging)", b)]
        out.append({"name": r.name, "path": str(r.path), "kind": r.kind, "workspace": r.workspace,
                    "default_base": default_base(r), "bases": (primary + [b for b in bases if b not in primary])[:40]})
    return out


def worktree_dir(repo, branch):
    """Sibling `worktrees/` folder next to the repo — never inside the source tree."""
    root = repo.path.parent if repo.kind == "normal" else (repo.path.parent if repo.path.name in (".bare", ".git") else repo.path.parent)
    return root / "worktrees" / ("%s-%s" % (repo.name, re.sub(r"[^A-Za-z0-9._-]+", "-", branch).strip("-")))


def create_worktree(repo, branch, base, path=None, clone_deps=True):
    """fetch origin/<base> (a failed fetch stops everything — never branch off a stale base),
    record its SHA, add the worktree on a new branch, verify HEAD == that SHA, then:
    copy `.env*.example` → `.env*`, and APFS-clone node_modules from the main checkout when the
    lockfiles are identical (copy-on-write: ~15 s for 100k files, no extra disk)."""
    steps = []
    dest = Path(path).expanduser() if path else worktree_dir(repo, branch)
    if dest.exists():
        return {"ok": False, "error": "%s already exists" % dest, "steps": steps}
    code, _, err = git(repo.path, "fetch", "origin", base, "--prune")
    if code != 0:
        return {"ok": False, "error": "git fetch origin %s failed — not creating from a stale base: %s" % (base, err.strip()), "steps": steps}
    _, sha, _ = git(repo.path, "rev-parse", "origin/%s" % base)
    sha = sha.strip()
    steps.append("fetched origin/%s @ %s" % (base, sha[:10]))
    code, _, err = git(repo.path, "show-ref", "--verify", "--quiet", "refs/heads/%s" % branch)
    if code == 0:
        return {"ok": False, "error": "branch %s already exists locally" % branch, "steps": steps}
    dest.parent.mkdir(parents=True, exist_ok=True)
    code, _, err = git(repo.path, "worktree", "add", "--no-track", "-b", branch, str(dest), "origin/%s" % base)
    if code != 0:
        return {"ok": False, "error": err.strip(), "steps": steps}
    _, head, _ = git(dest, "rev-parse", "HEAD")
    if head.strip() != sha:
        return {"ok": False, "error": "HEAD %s != origin/%s %s" % (head.strip()[:10], base, sha[:10]), "path": str(dest), "steps": steps}
    steps.append("worktree %s on new branch %s, HEAD verified" % (dest, branch))

    for ex in sorted(dest.glob(".env*.example")):
        target = dest / ex.name[: -len(".example")]
        if not target.exists():
            shutil.copy2(ex, target)
            steps.append("created %s from %s" % (target.name, ex.name))

    deps = []
    main = repo.path if repo.kind == "normal" else None
    if clone_deps and main:
        lock = next((l for l in LOCKFILES if (dest / l).exists()), None)
        for d in CLONABLE_DEPS:
            src = main / d
            if not src.is_dir() or src.is_symlink():
                continue
            if lock and (main / lock).exists() and (main / lock).read_bytes() != (dest / lock).read_bytes():
                deps.append({"dir": d, "cloned": False, "reason": "%s differs from the main checkout — run your install" % lock})
                continue
            t0 = time.time()
            p = subprocess.run(["cp", "-c", "-R", str(src), str(dest / d)], capture_output=True, text=True)
            ok = p.returncode == 0
            deps.append({"dir": d, "cloned": ok, "seconds": round(time.time() - t0, 1),
                         "reason": None if ok else p.stderr.strip()[:200]})
            steps.append(("cloned %s from the main checkout (APFS, %.0fs)" % (d, time.time() - t0)) if ok else "could not clone %s" % d)
    return {"ok": True, "path": str(dest), "branch": branch, "base": base, "base_sha": sha, "deps": deps, "steps": steps}


# ---------------------------------------------------------------- worklog (optional, via the companion project)

def worklog_today():
    """Today's Jira worklog from the companion project's `scripts/worklog_day.py --json`."""
    for ws in WORKSPACES:
        script = ws["assistant"] and ws["assistant"] / "scripts" / "worklog_day.py"
        if script and script.exists():
            p = subprocess.run([sys.executable, str(script), "--json"], capture_output=True, text=True,
                               cwd=str(ws["assistant"]), timeout=60)
            try:
                day = json.loads(p.stdout)["days"][0]
            except (ValueError, KeyError, IndexError):
                return {"available": True, "error": (p.stderr or p.stdout).strip()[-300:]}
            return {"available": True, "band": [7 * 3600, 9 * 3600], "target": 8 * 3600, "day": day, "at": int(time.time())}
    return {"available": False}


# ---------------------------------------------------------------- commands

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


def trash_for(path):
    """Next to the worktree, so moving into it is a same-volume rename (instant)."""
    return Path(path).parent / ".wt-trash"


_USED_TRASH = set()


BACKUPS = Path(os.environ.get("WT_BACKUPS") or STATE_HOME / "backups").expanduser()
BACKUP_MAX_BYTES = 1 << 30


def backup_changes(w):
    """Saves everything `remove --force` would destroy: `git diff HEAD --binary` (staged + unstaged
    tracked changes) and a copy of every untracked, non-ignored file. Returns (dir or "", error)."""
    path = Path(w["path"])
    code, out, err = git(path, "ls-files", "--others", "--exclude-standard", "-z")
    if code != 0:
        return None, "cannot list untracked files: " + err.strip()
    files = [f for f in out.split("\0") if f]
    code, _, _ = git(path, "diff", "--quiet", "HEAD")
    if not files and code == 0:
        return "", ""
    total = sum((path / f).lstat().st_size for f in files if (path / f).exists())
    if total > BACKUP_MAX_BYTES:
        return None, "untracked files total %.1f GB — too big to back up, clean them by hand" % (total / 1e9)
    dest = BACKUPS / ("%s-%s" % (w["name"], time.strftime("%Y%m%d-%H%M%S")))
    (dest / "untracked").mkdir(parents=True)
    with open(dest / "changes.patch", "wb") as fh:
        p = subprocess.run(["git", "--no-optional-locks", "-C", str(path), "diff", "HEAD", "--binary"],
                           stdout=fh, stderr=subprocess.PIPE)
    if p.returncode != 0:
        return None, "git diff failed: " + p.stderr.decode(errors="replace").strip()
    for f in files:
        src, dst = path / f, dest / "untracked" / f
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst, follow_symlinks=False)
    ref = w["branch"] or w["head"]
    (dest / "README.txt").write_text(
        "worktree: %s\nbranch:   %s\nhead:     %s\nremoved:  %s\n%d untracked file(s), patch %d bytes\n\n"
        "restore:\n  git -C %s worktree add <dir> %s\n  git -C <dir> apply --binary %s/changes.patch\n"
        "  cp -R %s/untracked/. <dir>/\n" % (
            path, w["branch"], w["head"], time.strftime("%Y-%m-%d %H:%M:%S"), len(files),
            (dest / "changes.patch").stat().st_size, w["repo_path"], ref, dest, dest))
    return str(dest), ""


def do_remove(w, force=False):
    """Git-ignored dependency/build dirs (node_modules alone is ~100k files, ~7s to unlink) are
    renamed into TRASH first — instant on the same volume — so `git worktree remove` only deletes
    the source tree. If git refuses, they are renamed back. TRASH is emptied by a detached `rm -rf`."""
    if w["missing"]:
        code, _, err = git(w["repo_path"], "worktree", "prune")
        return code == 0, err.strip()
    if force:
        backup, err = backup_changes(w)
        if backup is None:
            return False, "backup failed, nothing removed: " + err
        w["backup"] = backup
    parked = []
    for name in ignored_artifacts(w["path"]):
        d = Path(w["path"]) / name
        if d.is_symlink():
            continue
        trash = trash_for(w["path"])
        trash.mkdir(exist_ok=True)
        _USED_TRASH.add(trash)
        dest = trash / ("%s-%s-%d" % (w["name"], name.strip("."), time.time() * 1000))
        try:
            os.rename(d, dest)
            parked.append((d, dest))
        except OSError:
            pass
    code, _, err = git(w["repo_path"], "worktree", "remove", *(["--force"] if force else []), w["path"])
    if code != 0:
        for original, dest in parked:
            os.rename(dest, original)
        return False, err.strip()
    cache = load_cache()
    for key in [k for k in cache.get("sizes", {}) if k.startswith(w["path"] + "::")]:
        del cache["sizes"][key]
    save_cache(cache)
    return True, ""


def delete_branch(w):
    """-D only when the branch tip is exactly the merged PR's head (squash merges defeat -d);
    otherwise -d, which git refuses for anything not merged. Returns an error line or ''."""
    pr = w["pr"]
    exact = pr and pr["state"] == "MERGED" and w["head"] == pr.get("headRefOid")
    code, _, err = git(w["repo_path"], "branch", "-D" if exact else "-d", w["branch"])
    return "" if code == 0 else err.strip().splitlines()[0]


def purge_trash():
    entries = [str(p) for t in _USED_TRASH if t.is_dir() for p in t.iterdir()]
    if entries:
        subprocess.Popen(["nice", "-n", "15", "rm", "-rf", *entries], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def human_age(ts):
    d = (time.time() - ts) / 86400
    return "%dh" % (d * 24) if d < 1 else "%dd" % d


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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list")
    p.add_argument("--json", action="store_true")
    p.add_argument("--sizes", action="store_true", help="compute missing/expired dependency/build dir sizes")
    p.add_argument("--refresh", action="store_true", help="ignore the PR cache")
    p.add_argument("--offline", action="store_true", help="never call gh — PR states from cache, however old")
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
        data = collect(sizes=a.sizes, refresh=a.refresh, offline=a.offline)
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


if __name__ == "__main__":
    main()
