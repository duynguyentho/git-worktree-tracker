"""Today's Jira worklog via the companion project (optional)."""
import json
import subprocess
import sys
import time

from .config import WORKSPACES


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
