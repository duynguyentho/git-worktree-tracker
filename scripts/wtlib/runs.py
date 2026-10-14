"""/dev run state from the companion project."""
import json
from pathlib import Path

from .config import WORKSPACES


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
