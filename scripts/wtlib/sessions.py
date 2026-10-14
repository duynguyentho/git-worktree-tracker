"""Claude Code sessions per worktree and the Warp pane to jump to."""
import ctypes
import ctypes.util
import json
import re
import sqlite3
import time

from .config import CLAUDE_HOME, SESSION_LOOKBACK_S, WARP_DB
from .util import alive


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
