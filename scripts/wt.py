#!/usr/bin/env python3
"""git-worktree-tracker — backend + CLI of the Worktrees macOS app. The code lives in `wtlib/`.

    python3 scripts/wt.py list [--json] [--sizes] [--refresh]
    python3 scripts/wt.py open <name|KEY> [--app webstorm|code|cursor|warp|finder]
    python3 scripts/wt.py kill <name|KEY> [--yes]
    python3 scripts/wt.py remove <name|KEY> [--yes]
    python3 scripts/wt.py prune [--yes]

Sources: `git worktree list` of every repo found under the configured folders, `gh pr list` (cached),
`.claude/memory/dev-runs.json`, `lsof` (processes whose cwd is inside a worktree).
Removal is `git worktree remove` without --force, and only when nothing can be lost.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from wtlib.cli import main  # noqa: E402

if __name__ == "__main__":
    main(__doc__)
