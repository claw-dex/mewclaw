---
name: rebase-submodules-against-v1-base
description: Rebase all submodule branches onto the latest remote v1/base, then force-push. Use when the user runs /rebase-submodules-against-v1-base or asks to rebase/sync submodule branches against v1/base.
tools: Bash
---

# Rebase Submodules

Fetch the latest remote and rebase all three submodule branches onto `origin/v1/base`, then force-push each branch.

## Submodules

| Path | Branch |
|------|--------|
| `v1/codasst` | `v1/codasst` |
| `v1/engagius` | `v1/engagius` |
| `v1/proximate` | `v1/proximate` |

## Steps

For each submodule, run from the repo root:

```bash
# 1. Fetch latest remote (all submodules share the same remote)
git -C v1/codasst fetch origin
git -C v1/engagius fetch origin
git -C v1/proximate fetch origin

# 2. Rebase each branch onto origin/v1/base
git -C v1/codasst rebase origin/v1/base
git -C v1/engagius rebase origin/v1/base
git -C v1/proximate rebase origin/v1/base

# 3. Force-push
bash scripts/push_submodules.sh
```

If any rebase hits a conflict, stop and report which submodule conflicted and which files are in conflict — do not attempt to resolve automatically.

Report the final state of each submodule: branch name, new HEAD commit, and push result.
