#!/usr/bin/env bash
#
# sync-upstream.sh — for each submodule, fast-forward `main` to its upstream,
# then rebase the custom feature branches on top of the new main.
#
# Handles stacked branches: list a submodule's branches in stack order
# (parent first) and each is rebased onto the rebased version of the one
# before it via `git rebase --onto`, so shared commits aren't duplicated.
#
# Safe by default:
#   - Skips a submodule whose working tree is dirty.
#   - Uses `merge --ff-only` for main (never creates a merge or silently diverges).
#   - Aborts a rebase on conflict and stops, rather than leaving a mess.
#   - DRY-RUN by default: prints the force-push commands instead of pushing.
#     Pass --push to actually push.
#
# Usage:
#   scripts/sync-upstream.sh           # fetch, ff main, rebase locally, print pushes
#   scripts/sync-upstream.sh --push    # ...and push (main: normal; branches: --force-with-lease)

set -euo pipefail

# --- config -----------------------------------------------------------------
# Submodules to process, and each one's custom branches in STACK ORDER
# (parent first; branch N is assumed stacked on branch N-1, branch 0 on main).
SUBMODULES=(localsend-server localsend-web)
declare -A BRANCHES=(
  [localsend-server]="feat/room-codes"
  [localsend-web]="feat/basepath feat/room-codes"
)
# Upstream URL per submodule — auto-added as the `upstream` remote if missing.
declare -A UPSTREAM_URL=(
  [localsend-server]="https://github.com/localsend/localsend.git"
  [localsend-web]="https://github.com/localsend/web.git"
)
UPSTREAM_REMOTE=upstream
MAIN_BRANCH=main
# ----------------------------------------------------------------------------

PUSH=0
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'
info(){ printf '%s%s%s\n' "$c_bold" "$*" "$c_reset"; }
ok(){   printf '%s%s%s\n' "$c_grn"  "$*" "$c_reset"; }
warn(){ printf '%s%s%s\n' "$c_yel"  "$*" "$c_reset"; }
die(){  printf '%s%s%s\n' "$c_red"  "$*" "$c_reset" >&2; exit 1; }

short(){ git rev-parse --short "$1"; }

push_cmds=()

sync_submodule() {
  local sub="$1"
  local dir="$ROOT/$sub"
  local branches; read -r -a branches <<< "${BRANCHES[$sub]:-}"

  info "==== $sub ===="
  if [ ! -e "$dir/.git" ]; then warn "  not a git checkout, skipping"; return; fi
  cd "$dir"

  if [ -n "$(git status --porcelain)" ]; then
    warn "  working tree dirty — skipping (commit or stash first)"; cd "$ROOT"; return
  fi
  if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    local want_url="${UPSTREAM_URL[$sub]:-}"
    if [ -z "$want_url" ]; then
      warn "  no '$UPSTREAM_REMOTE' remote and no URL configured for $sub — skipping"
      cd "$ROOT"; return
    fi
    git remote add "$UPSTREAM_REMOTE" "$want_url"
    ok "  added '$UPSTREAM_REMOTE' remote -> $want_url"
  fi

  local start_branch; start_branch="$(git symbolic-ref --quiet --short HEAD || echo '')"

  git fetch "$UPSTREAM_REMOTE" --quiet
  git fetch origin --quiet || true

  local old_main new_main
  old_main="$(git rev-parse "$MAIN_BRANCH")"

  git checkout --quiet "$MAIN_BRANCH"
  if ! git merge --ff-only "$UPSTREAM_REMOTE/$MAIN_BRANCH" >/dev/null 2>&1; then
    warn "  $MAIN_BRANCH is not fast-forwardable to $UPSTREAM_REMOTE/$MAIN_BRANCH"
    warn "  (fork main diverged from upstream — resolve manually). Skipping $sub."
    [ -n "$start_branch" ] && git checkout --quiet "$start_branch"
    cd "$ROOT"; return
  fi
  new_main="$(git rev-parse "$MAIN_BRANCH")"

  if [ "$old_main" = "$new_main" ]; then
    ok "  $MAIN_BRANCH already current ($(short "$new_main"))"
  else
    ok "  $MAIN_BRANCH: $(short "$old_main") -> $(short "$new_main")"
    push_cmds+=("(cd '$sub' && git push origin $MAIN_BRANCH)")
  fi

  # Rebase the stack. prev_old/prev_new track the previous link's OLD and NEW
  # base SHAs so each branch replays only its own commits onto the new base.
  local prev_old="$old_main" prev_new="$new_main"
  local br old_tip
  for br in "${branches[@]}"; do
    if ! git rev-parse --verify --quiet "refs/heads/$br" >/dev/null; then
      warn "  branch $br not found, skipping"; continue
    fi
    old_tip="$(git rev-parse "$br")"
    if [ "$prev_old" = "$prev_new" ]; then
      ok "  $br: base unchanged, nothing to rebase"
    else
      info "  rebasing $br --onto $(short "$prev_new") (was on $(short "$prev_old"))"
      if ! git rebase --onto "$prev_new" "$prev_old" "$br" >/dev/null 2>&1; then
        git rebase --abort >/dev/null 2>&1 || true
        die "  rebase of $br hit conflicts — aborted. Resolve $sub by hand, then re-run."
      fi
      ok "  $br rebased: $(short "$old_tip") -> $(short "$br")"
      push_cmds+=("(cd '$sub' && git push --force-with-lease origin $br)")
    fi
    prev_old="$old_tip"
    prev_new="$(git rev-parse "$br")"
  done

  [ -n "$start_branch" ] && git checkout --quiet "$start_branch"
  cd "$ROOT"
}

for sub in "${SUBMODULES[@]}"; do
  sync_submodule "$sub"
  echo
done

if [ "${#push_cmds[@]}" -eq 0 ]; then
  ok "Everything already in sync — nothing to push."
  exit 0
fi

info "Pending pushes:"
printf '  %s\n' "${push_cmds[@]}"
echo

if [ "$PUSH" -eq 1 ]; then
  info "Pushing (--push given)…"
  for c in "${push_cmds[@]}"; do
    echo "  + $c"
    eval "$c"
  done
  ok "Pushed. Now bump the parent repo's submodule pointers:"
  echo "  git add ${SUBMODULES[*]} && git commit -m 'bump submodules after upstream sync'"
else
  warn "Dry-run (no --push). Review the rebases above, then re-run with --push"
  warn "or run the commands yourself. Rebases rewrote history locally — the parent"
  warn "repo's pinned submodule SHAs will need bumping after you push."
fi
