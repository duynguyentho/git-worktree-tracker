"""Settings: workspaces from ~/.config/git-worktree-tracker/config.json, paths and tunables."""
import json
import os
import re
import shutil
from pathlib import Path


CONFIG_PATH = Path(os.environ.get("WT_CONFIG", "~/.config/git-worktree-tracker/config.json")).expanduser()


def load_config():
    try:
        return json.loads(CONFIG_PATH.read_text())
    except (OSError, ValueError):
        return {}


CONFIG = load_config()


# A workspace = a named set of folders plus its own Jira URL, ticket pattern, repo labels and
# companion project. Legacy flat configs (top-level "bases"/"base") read as one workspace.
# Unconfigured → whichever common code folders exist (never ~/Documents, which would trigger a
# macOS privacy prompt before the user picked anything).
DEFAULT_CANDIDATES = ["~/Projects", "~/Developer", "~/code", "~/Code", "~/src", "~/dev", "~/work",
                      "~/repos", "~/git", "~/GitHub", "~/workspace"]


WORKSPACE_KEYS = ("name", "bases", "base", "jira_url", "ticket_regex", "repos", "assistant", "scan_depth")


DEFAULT_TICKET_RE = r"\b[A-Z][A-Z0-9]+-\d+\b"


def _norm_workspace(ws, configured):
    bases = ws.get("bases") or ([ws["base"]] if ws.get("base") else [])
    assistant = os.environ.get("WT_ASSISTANT") or ws.get("assistant")
    assistant = Path(assistant).expanduser() if assistant else None
    return {
        "name": ws.get("name") or "Default",
        "bases": list(dict.fromkeys(str(Path(b).expanduser()) for b in bases)),
        "jira_url": ws.get("jira_url"),
        "ticket_re": re.compile(ws.get("ticket_regex") or DEFAULT_TICKET_RE),
        "repos": ws.get("repos") or {},
        "assistant": assistant,
        "dev_runs": os.environ.get("WT_DEV_RUNS") or (assistant and assistant / ".claude" / "memory" / "dev-runs.json"),
        "scan_depth": int(ws.get("scan_depth") or CONFIG.get("scan_depth") or 3),
        "configured": configured,
    }


def load_workspaces(cfg):
    if os.environ.get("WT_BASE"):
        flat = {k: cfg[k] for k in WORKSPACE_KEYS if k in cfg}
        return [_norm_workspace(dict(flat, bases=[os.environ["WT_BASE"]]), True)]
    if cfg.get("workspaces"):
        return [_norm_workspace(w, True) for w in cfg["workspaces"]]
    flat = {k: cfg[k] for k in WORKSPACE_KEYS if k in cfg}
    if flat.get("bases") or flat.get("base"):
        return [_norm_workspace(flat, True)]
    found = [c for c in DEFAULT_CANDIDATES if Path(c).expanduser().is_dir()]
    return [_norm_workspace(dict(flat, bases=found), False)]


WORKSPACES = load_workspaces(CONFIG)


CONFIGURED = any(w["configured"] for w in WORKSPACES)


BASES = list(dict.fromkeys(b for w in WORKSPACES for b in w["bases"]))


SCAN_SKIP = {"node_modules", "vendor", "Library", "Applications", ".Trash", "target", "dist", "build"}


STATE_HOME = Path("~/Library/Application Support/git-worktree-tracker").expanduser()


CACHE_PATH = Path(os.environ.get("WT_CACHE_PATH") or "~/Library/Caches/git-worktree-tracker/wt_cache.json").expanduser()


PR_WATCH_DIR = os.environ.get("WT_PR_WATCH_DIR") or next(
    (str(w["assistant"] / "scripts") for w in WORKSPACES if w["assistant"]), None)


GH = os.environ.get("GH_BIN") or shutil.which("gh") or "/opt/homebrew/bin/gh"


PR_TTL = 10 * 60


SIZE_TTL = 12 * 3600


UNTRACKED_TTL = 60


ACTIVE_DAYS = 2


STALE_DAYS = 14


FORCE_MIN_IDLE_H = 24


EDITORS = {
    "webstorm": "WebStorm",
    "code": "Visual Studio Code",
    "cursor": "Cursor",
    "warp": "Warp",
    "finder": "Finder",
}


ARTIFACT_DIRS = CONFIG.get("artifact_dirs") or [
    "node_modules", ".next", ".nuxt", ".turbo", "dist",          # JS / TS
    ".venv", "venv", ".tox", ".mypy_cache", ".pytest_cache",     # Python
    "vendor",                                                    # Go / PHP (only when git-ignored)
    "target", "build", ".gradle",                                # Rust / JVM
    ".build", "Pods", "DerivedData",                             # Swift / iOS
]


ECOSYSTEM_MARKERS = [
    ("go.mod", "go"), ("pyproject.toml", "python"), ("requirements.txt", "python"), ("setup.py", "python"),
    ("Pipfile", "python"), ("package.json", "node"), ("Cargo.toml", "rust"), ("pom.xml", "java"),
    ("build.gradle", "java"), ("build.gradle.kts", "kotlin"), ("Package.swift", "swift"), ("Gemfile", "ruby"),
    ("composer.json", "php"), ("mix.exs", "elixir"), ("main.tf", "terraform"),
]


STATE_ORDER = ["active", "review", "idle", "stale", "merged", "closed", "missing"]


PRUNABLE = ("merged", "closed", "missing")


CLAUDE_HOME = Path.home() / ".claude"


WARP_DB = (Path.home() / "Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support"
           / "dev.warp.Warp-Stable/warp.sqlite")


SESSION_LOOKBACK_S = 8 * 3600


PR_STATUS_TTL = 120


LOCKFILES = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock"]


CLONABLE_DEPS = ["node_modules"]  # relocatable as-is; a .venv bakes absolute paths in, so never cloned


BACKUPS = Path(os.environ.get("WT_BACKUPS") or STATE_HOME / "backups").expanduser()


BACKUP_MAX_BYTES = 1 << 30
