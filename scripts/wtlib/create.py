"""Creating a worktree on a new branch off a freshly fetched base."""
import shutil
import subprocess
import time
from pathlib import Path

from .config import CLONABLE_DEPS, LOCKFILES
from .repos import worktree_dir
from .util import git


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
    main_checkout = repo.path if repo.kind == "normal" else None
    if clone_deps and main_checkout:
        lock = next((l for l in LOCKFILES if (dest / l).exists()), None)
        for d in CLONABLE_DEPS:
            src = main_checkout / d
            if not src.is_dir() or src.is_symlink():
                continue
            if lock and (main_checkout / lock).exists() and (main_checkout / lock).read_bytes() != (dest / lock).read_bytes():
                deps.append({"dir": d, "cloned": False, "reason": "%s differs from the main checkout — run your install" % lock})
                continue
            t0 = time.time()
            p = subprocess.run(["cp", "-c", "-R", str(src), str(dest / d)], capture_output=True, text=True)
            ok = p.returncode == 0
            deps.append({"dir": d, "cloned": ok, "seconds": round(time.time() - t0, 1),
                         "reason": None if ok else p.stderr.strip()[:200]})
            steps.append(("cloned %s from the main checkout (APFS, %.0fs)" % (d, time.time() - t0)) if ok else "could not clone %s" % d)
    return {"ok": True, "path": str(dest), "branch": branch, "base": base, "base_sha": sha, "deps": deps, "steps": steps}
