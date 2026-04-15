#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SUBMODULES=(
  "v1/codasst"
  "v1/engagius"
  "v1/proximate"
)

for sub in "${SUBMODULES[@]}"; do
  dir="$REPO_ROOT/$sub"
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
  echo "==> [$sub] force-pushing branch '$branch' to origin..."
  git -C "$dir" push --force-with-lease origin "$branch"
  echo "    done."
done

echo ""
echo "All submodule branches pushed."
