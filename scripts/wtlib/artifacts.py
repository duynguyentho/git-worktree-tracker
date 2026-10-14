"""Git-ignored dependency/build folders and the stack each worktree uses."""
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .config import ARTIFACT_DIRS, ECOSYSTEM_MARKERS, SIZE_TTL
from .util import load_cache, run, save_cache


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
