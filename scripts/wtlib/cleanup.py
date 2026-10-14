"""Safe removal: backups for --force, parking dependency folders, branch deletion."""
import os
import shutil
import subprocess
import time
from pathlib import Path

from .artifacts import ignored_artifacts
from .config import BACKUPS, BACKUP_MAX_BYTES
from .util import git, load_cache, save_cache


def trash_for(path):
    """Next to the worktree, so moving into it is a same-volume rename (instant)."""
    return Path(path).parent / ".wt-trash"


_USED_TRASH = set()


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
