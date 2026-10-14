# git-worktree-tracker

`Worktrees.app` — 
A macOS app for the git worktrees you have checked out in several repos at once. It shows
what each worktree is doing, what it costs in disk and memory, and what it needs from you.
It also removes worktrees you are done with, and nothing is lost when it does.

- **State per worktree.** Each worktree is grouped as active, in review, idle, stale or
  merged. This uses uncommitted files, the open PR, `/dev` run state and recent activity.
- **PR / CI status.** Shows checks, conflicts and review decision, and how many commits the
  worktree is behind the PR base. "Needs attention" lists every PR with failing checks, a
  conflict or requested changes.
- **Live resources.** CPU and memory footprint of every process running in a worktree,
  child processes included. Sampled with `libproc` every second, with 2-minute charts.
- **Jump to the right Warp tab.** Finds the Claude Code session or process working on a
  worktree and focuses its pane through `warp://session/<uuid>`. If there is none, it opens
  a new tab there.
- **Safe cleanup.**
  - Removal never loses work. A worktree with uncommitted files, unpushed commits, running
    processes or an active `/dev` run is refused.
  - `node_modules` (about 100k files) is moved aside first, so removal takes seconds, and
    it is deleted in the background.
  - **Force remove** backs up `changes.patch` and untracked files to `.wt-backups/` first.
    It refuses anything changed in the last 24 h.
  - Local branches are kept unless you ask, and then only merged ones are deleted.

## Layout

| Path | What |
|------|------|
| `app/WorktreeBar.swift` | SwiftUI app: main window and menu bar extra |
| `app/build.sh` | Builds `Worktrees.app` with `swiftc`, installs it into `~/Applications` |
| `scripts/wt.py` | Backend and CLI. The app calls it for every read and every removal |

## Build

Requires macOS 14+ and the Xcode command line tools.

```bash
app/build.sh            # build, install to ~/Applications, launch
app/build.sh --login    # also add to Login Items
```

## CLI

```bash
python3 scripts/wt.py list [--json] [--sizes] [--refresh] [--offline]
python3 scripts/wt.py open <name|KEY> [--app webstorm|code|cursor|warp|finder]
python3 scripts/wt.py remove <name|KEY>... [--force] [--delete-branch] [--yes]
python3 scripts/wt.py prune [--yes]
python3 scripts/wt.py procs [--with-sessions] [PATH...]
python3 scripts/wt.py kill <name|KEY> [--yes]
python3 scripts/wt.py fetch <name|KEY>
```

## Configuration

Settings live outside the repo in `~/.config/git-worktree-tracker/config.json` (every key optional):

```json
{
  "base": "~/Projects/acme",
  "assistant": "~/Projects/my-assistant",
  "jira_url": "https://acme.atlassian.net",
  "ticket_regex": "\\bABC-\\d+\\b",
  "repos": { "payments-service": { "label": "payments", "hue": 250 } }
}
```

| Key | Default | Purpose |
|-----|---------|---------|
| `base` | `~/Projects` | Folder holding the repos; worktrees are found through each repo's `git worktree list` |
| `assistant` | — | Optional companion project: `/dev` run state (`.claude/memory/dev-runs.json`) and `scripts/pr_watch.py` for PR/CI status. Without it those panels are hidden |
| `jira_url` | — | Enables the Jira buttons for ticket keys |
| `ticket_regex` | `\b[A-Z][A-Z0-9]+-\d+\b` | How a ticket key is read from a branch or folder name |
| `repos` | name + derived colour | Short label and OKLCH hue per repo |

Environment variables override the file: `WT_BASE`, `WT_ASSISTANT`, `WT_DEV_RUNS`, `WT_PR_WATCH_DIR`,
`WT_CACHE_PATH` (default `data/wt_cache.json`), `WT_CONFIG`, `GH_BIN`.
