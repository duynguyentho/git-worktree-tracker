"""Subprocess, git and cache helpers shared by every module."""
import json
import os
import subprocess
import time

from .config import CACHE_PATH


def run(cmd, cwd=None, timeout=60):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", PATH=os.environ.get("PATH", "") + ":/opt/homebrew/bin:/usr/local/bin")
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)
    return p.returncode, p.stdout, p.stderr


def git(path, *args):
    return run(["git", "--no-optional-locks", "-C", str(path), *args])


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


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def human_age(ts):
    d = (time.time() - ts) / 86400
    return "%dh" % (d * 24) if d < 1 else "%dd" % d
