#!/usr/bin/env bash
# 证明：一个没有 .git 的目录嵌在某个 git 仓里时，`git worktree add` 会注册到**外层仓**。
# 用法: bash nested-nongit-project.sh <scratch-dir>
set -eu
SCRATCH=${1:-/tmp/poc-nested}
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/outer/proj-no-git"
cd "$SCRATCH/outer"
git init -q .; git -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
echo "outer_before=$(git worktree list --porcelain | grep -c '^worktree ')"
cd "$SCRATCH/outer/proj-no-git"
echo "proj_has_git=$(test -e .git && echo yes || echo no)"
echo "rev_parse_toplevel=$(git rev-parse --show-toplevel)"
git worktree add --detach --no-checkout "$SCRATCH/outer/proj-no-git/.newbee/workspaces/colony-x" HEAD >/dev/null
cd "$SCRATCH/outer"
echo "outer_after=$(git worktree list --porcelain | grep -c '^worktree ')"
echo "registry_entry=$(ls .git/worktrees | wc -l)"
