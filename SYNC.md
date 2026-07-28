# Fork sync workflow

This is a fork of `cogwheel0/conduit` (`upstream` remote); `origin` is this fork.

A gitignored, local-only `./sync` script (not tracked, does not survive a fresh clone) fetches `upstream/main`, rebases the current branch onto it, and force-pushes to `origin`. It uses `rerere` plus `tool/resolve_sync_conflicts.dart` to auto-resolve two conflict shapes that recur on every sync:

- Hook-stripped-comment hunks: a global git hook at `~/.git-hooks` strips non-doc comments from every staged file on commit, in every repo. Committing any change to an upstream-owned file here strips that file's pre-existing upstream comments too, and that deletion later collides with an unrelated upstream edit at the same spot. The resolution is always to keep upstream's side of that hunk.
- Fast-forward submodule pointer conflicts, where one side's commit is an ancestor of the other.

Anything that doesn't match one of those shapes stops the rebase and hands off.

## Minimizing the diff against upstream

New functionality goes under wholly fork-owned paths (`lib/inference_gateway/`, `test/inference_gateway/`) that can never conflict, since upstream has nothing there to merge against. A file that upstream also owns is touched by at most one commit total on the branch; a later fix to that same file is folded in with `git commit --fixup=<sha>` + `git rebase -i --autosquash upstream/main` rather than added as a new commit, since two commits touching the same upstream file means resolving that file's conflict twice on every future sync.

## Hook bypass boundary

A separate global `PreToolUse` hook blocks Claude from typing hook-bypass git commands (`--no-verify`, `-c core.hooksPath=`, `GIT_CONFIG_*` env tricks, etc.) directly into a shell. A script the user runs themselves — `./sync` — may bypass the hook internally for its own commits, since the user chose to invoke it and can read what it does.
