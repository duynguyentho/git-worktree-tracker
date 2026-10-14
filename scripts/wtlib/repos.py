"""Finding repositories (normal, bare, and via linked worktrees) and their worktrees."""
import os
import re
import sys
from pathlib import Path

from .config import SCAN_SKIP, WORKSPACES
from .util import git


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
    main_path = os.path.realpath(str(repo))
    return [i for i in items if not i.get("bare") and os.path.realpath(i.get("worktree", "")) != main_path]


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
