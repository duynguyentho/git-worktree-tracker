"""Processes running inside a worktree (cwd + descendants), with RAM/CPU and ports."""
import os

from .util import run


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
