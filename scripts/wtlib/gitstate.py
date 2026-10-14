"""Per-worktree git state: dirty files, upstream, unpushed commits, last activity."""
import re
from pathlib import Path

from .util import git


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
