#!/usr/bin/env bash
# Releases a new version of the extension: sets the version, moves the CHANGELOG.md
# "Unreleased" notes under it, builds the .vsix, commits and tags vX.Y.Z, pushes,
# then publishes to GitHub Releases, the VS Code Marketplace and Open VSX.
#
# Usage: ./scripts/publish.sh <patch|minor|major|X.Y.Z|current> [options]
#   patch | minor | major  Bump the version in package.json (1.2.3 -> 1.2.4 / 1.3.0 / 2.0.0)
#   X.Y.Z                  Use this exact version
#   current                Release the version already in package.json, e.g. to finish
#                          a release whose publish step failed (already-published targets are skipped)
#
# Options:
#   --pre-release       Publish as a pre-release on all targets
#   --skip-github       Don't create a GitHub release (the commit and tag are still pushed)
#   --skip-marketplace  Don't publish to the VS Code Marketplace
#   --skip-openvsx      Don't publish to Open VSX
#   --dry-run           Build the .vsix for the new version, then put the files back; publish nothing
#   -y, --yes           Don't ask for confirmation (required when not run in a terminal)
#
# Credentials:
#   GitHub       gh CLI login ("gh auth login") or GH_TOKEN
#   Marketplace  trusted publishing (OIDC) when run by the Release workflow on GitHub,
#                otherwise VSCE_PAT (global Azure DevOps PATs stop working on 1 Dec 2026)
#   Open VSX     OVSX_PAT, or trusted publishing when run by the Release workflow
# Tokens are read from the environment, or from a .env file next to package.json.
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
step() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
BUMP=""
PRE_RELEASE=0 SKIP_GITHUB=0 SKIP_MARKETPLACE=0 SKIP_OPENVSX=0 DRY_RUN=0 YES=0
for arg in "$@"; do
  case "$arg" in
    --pre-release) PRE_RELEASE=1 ;;
    --skip-github) SKIP_GITHUB=1 ;;
    --skip-marketplace) SKIP_MARKETPLACE=1 ;;
    --skip-openvsx) SKIP_OPENVSX=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -y|--yes) YES=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $arg" ;;
    *) [ -z "$BUMP" ] || die "only one version argument is allowed"; BUMP="$arg" ;;
  esac
done
[ -n "$BUMP" ] || { usage >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Reads KEY=VALUE lines from .env. Variables already set in the environment win.
load_env_file() {
  local line key value
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] || continue
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"; fi
    if [ -z "${!key:-}" ]; then export "$key=$value"; fi
  done < "$1"
}
load_env_file .env

# GitHub Actions provides an OIDC ID token when the job has "permissions: id-token: write".
OIDC=0
if [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then OIDC=1; fi

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
for tool in git node npm; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$ROOT is not a git repository"
git rev-parse --verify --quiet HEAD >/dev/null || die "the repository has no commits yet"
[ -z "$(git status --porcelain)" ] || die "the working tree has uncommitted changes; commit or stash them first"
BRANCH="$(git symbolic-ref --quiet --short HEAD)" || die "HEAD is detached; check out a branch first"

HAS_ORIGIN=0
if git remote get-url origin >/dev/null 2>&1; then
  HAS_ORIGIN=1
  git fetch --quiet --tags origin || die "could not fetch from origin"
  if git rev-parse --verify --quiet "refs/remotes/origin/$BRANCH" >/dev/null; then
    behind="$(git rev-list --count "HEAD..origin/$BRANCH")"
    [ "$behind" = 0 ] || die "$BRANCH is $behind commit(s) behind origin/$BRANCH; pull first"
  fi
fi

NAME="$(node -p "require('./package.json').name")"
PUBLISHER="$(node -p "require('./package.json').publisher")"
CURRENT="$(node -p "require('./package.json').version")"

next_version() {
  node -e '
    const [current, bump] = process.argv.slice(1);
    const m = /^(\d+)\.(\d+)\.(\d+)/.exec(current);
    if (!m) { console.error(`cannot read version "${current}" in package.json`); process.exit(1); }
    let [major, minor, patch] = m.slice(1).map(Number);
    if (bump === "major") { major++; minor = 0; patch = 0; }
    else if (bump === "minor") { minor++; patch = 0; }
    else { patch++; }
    console.log(`${major}.${minor}.${patch}`);
  ' "$1" "$2"
}

case "$BUMP" in
  patch|minor|major) VERSION="$(next_version "$CURRENT" "$BUMP")" ;;
  current) VERSION="$CURRENT" ;;
  *)
    VERSION="${BUMP#v}"
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
      die "invalid version '$BUMP': use patch, minor, major, current or X.Y.Z (the Marketplace rejects suffixes like -beta; use --pre-release instead)"
    ;;
esac

TAG="v$VERSION"
VSIX="releases/$NAME-$VERSION.vsix"
BUMPED=0
[ "$VERSION" = "$CURRENT" ] || BUMPED=1

TAG_EXISTS=0
if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
  TAG_EXISTS=1
  [ "$BUMPED" = 0 ] || die "tag $TAG already exists; pick another version"
  [ "$(git rev-list -n 1 "$TAG")" = "$(git rev-parse HEAD)" ] ||
    die "tag $TAG already exists on another commit; release a new version (patch, minor or major) instead"
fi

if [ "$BRANCH" != main ] && [ "$BRANCH" != master ]; then
  warn "you are releasing from branch '$BRANCH', not main"
fi

problems=""
if [ "$SKIP_GITHUB" = 0 ]; then
  if ! command -v gh >/dev/null 2>&1; then
    problems="$problems\n  - gh (GitHub CLI) is not installed: https://cli.github.com (or pass --skip-github)"
  elif ! gh auth status --hostname github.com >/dev/null 2>&1; then
    problems="$problems\n  - gh is not logged in: run 'gh auth login' or set GH_TOKEN (or pass --skip-github)"
  fi
  [ "$HAS_ORIGIN" = 1 ] ||
    problems="$problems\n  - no 'origin' remote: create the GitHub repository and add it as origin (or pass --skip-github)"
fi
[ "$SKIP_MARKETPLACE" = 1 ] || [ "$OIDC" = 1 ] || [ -n "${VSCE_PAT:-}" ] ||
  problems="$problems\n  - no VS Code Marketplace credentials: run the Release workflow on GitHub, or set VSCE_PAT (or pass --skip-marketplace)"
[ "$SKIP_OPENVSX" = 1 ] || [ "$OIDC" = 1 ] || [ -n "${OVSX_PAT:-}" ] ||
  problems="$problems\n  - OVSX_PAT is not set (or pass --skip-openvsx)"
if [ -n "$problems" ]; then
  printf 'Release prerequisites are missing:%b\n' "$problems" >&2
  if [ "$DRY_RUN" = 1 ]; then warn "continuing because this is a dry run"; else exit 1; fi
fi

TARGETS=""
[ "$SKIP_GITHUB" = 1 ] || TARGETS="$TARGETS, GitHub release"
if [ "$SKIP_MARKETPLACE" = 0 ]; then
  if [ "$OIDC" = 1 ]; then TARGETS="$TARGETS, VS Code Marketplace (trusted publishing)"; else TARGETS="$TARGETS, VS Code Marketplace (VSCE_PAT)"; fi
fi
if [ "$SKIP_OPENVSX" = 0 ]; then
  if [ -z "${OVSX_PAT:-}" ] && [ "$OIDC" = 1 ]; then TARGETS="$TARGETS, Open VSX (trusted publishing)"; else TARGETS="$TARGETS, Open VSX (OVSX_PAT)"; fi
fi
TARGETS="${TARGETS#, }"
[ -n "$TARGETS" ] || TARGETS="nothing (all targets skipped)"

echo "Release plan$([ "$DRY_RUN" = 1 ] && echo ' (dry run)')"
echo "  extension:  $PUBLISHER.$NAME"
if [ "$BUMPED" = 1 ]; then
  echo "  version:    $CURRENT -> $VERSION (tag $TAG)$([ "$PRE_RELEASE" = 1 ] && echo ', pre-release')"
else
  echo "  version:    $VERSION, unchanged (tag $TAG)$([ "$PRE_RELEASE" = 1 ] && echo ', pre-release')"
fi
echo "  branch:     $BRANCH$([ "$HAS_ORIGIN" = 1 ] || echo ' (no origin remote: nothing is pushed)')"
echo "  publish to: $TARGETS"

if [ "$DRY_RUN" = 0 ] && [ "$YES" = 0 ]; then
  [ -t 0 ] || die "not running in a terminal: pass --yes to confirm"
  read -r -p "Continue? [y/N] " answer
  case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 1 ;; esac
fi

# ---------------------------------------------------------------------------
# On failure: put the version files back if nothing was committed yet,
# otherwise explain how to finish the release.
# ---------------------------------------------------------------------------
TRACKED_FILES=""
for f in package.json package-lock.json CHANGELOG.md; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then TRACKED_FILES="$TRACKED_FILES $f"; fi
done
FILES_CHANGED=0
COMMITTED=0

restore_files() {
  if [ "$FILES_CHANGED" = 1 ] && [ "$COMMITTED" = 0 ]; then
    # shellcheck disable=SC2086
    git checkout --quiet -- $TRACKED_FILES
    FILES_CHANGED=0
    echo "Put back:$TRACKED_FILES"
  fi
}

resume_command() {
  local cmd="./scripts/publish.sh current"
  [ "$PRE_RELEASE" = 0 ] || cmd="$cmd --pre-release"
  [ "$SKIP_GITHUB" = 0 ] || cmd="$cmd --skip-github"
  [ "$SKIP_MARKETPLACE" = 0 ] || cmd="$cmd --skip-marketplace"
  [ "$SKIP_OPENVSX" = 0 ] || cmd="$cmd --skip-openvsx"
  echo "$cmd"
}

on_exit() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    restore_files
    if [ "$COMMITTED" = 1 ] || [ "$TAG_CREATED" = 1 ]; then
      echo >&2
      echo "The release commit/tag for $TAG exists locally. Fix the problem above, then finish with:" >&2
      echo "  $(resume_command)" >&2
    fi
  fi
}
TAG_CREATED=0
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Version, changelog, build
# ---------------------------------------------------------------------------
step "Installing dependencies (npm ci)"
npm ci --no-audit --no-fund

if [ "$BUMPED" = 1 ]; then
  step "Setting version $VERSION"
  FILES_CHANGED=1
  npm version "$VERSION" --no-git-tag-version >/dev/null

  if [ -f CHANGELOG.md ] && grep -q '^## \[Unreleased\]' CHANGELOG.md; then
    # "## [Unreleased]" stays on top (empty); its notes move under "## [X.Y.Z] - date".
    tmp="$(mktemp)"
    awk -v heading="## [$VERSION] - $(date +%Y-%m-%d)" '
      !done && /^## \[Unreleased\]/ { print; print ""; print heading; done = 1; next }
      { print }
    ' CHANGELOG.md > "$tmp"
    cat "$tmp" > CHANGELOG.md
    rm -f "$tmp"
  else
    warn "CHANGELOG.md has no '## [Unreleased]' heading; leaving it unchanged"
  fi
fi

# Notes for this version: the lines under "## [X.Y.Z]" up to the next "## " heading.
NOTES=""
if [ -f CHANGELOG.md ]; then
  NOTES="$(awk -v start="## [$VERSION]" '
    index($0, start) == 1 { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' CHANGELOG.md)"
fi
if ! printf '%s' "$NOTES" | grep -q '[^[:space:]]'; then
  NOTES=""
  warn "CHANGELOG.md has no notes for $VERSION; the GitHub release will use generated notes"
fi

step "Building $VSIX"
if [ "$PRE_RELEASE" = 1 ]; then
  bash scripts/package.sh --pre-release
else
  bash scripts/package.sh
fi

if [ "$DRY_RUN" = 1 ]; then
  restore_files
  echo
  echo "Dry run finished: built $VSIX. package.json and CHANGELOG.md are back at $CURRENT."
  echo "A real run would now commit, tag $TAG, push, and publish to: $TARGETS"
  exit 0
fi

# ---------------------------------------------------------------------------
# Commit, tag, push
# ---------------------------------------------------------------------------
if [ "$BUMPED" = 1 ]; then
  step "Committing release $TAG"
  # shellcheck disable=SC2086
  git add -- $TRACKED_FILES
  git commit --quiet -m "chore(release): $TAG"
  COMMITTED=1
fi
if [ "$TAG_EXISTS" = 0 ]; then
  git tag -a "$TAG" -m "$NAME $TAG"
  TAG_CREATED=1
fi

if [ "$HAS_ORIGIN" = 1 ]; then
  step "Pushing $BRANCH and $TAG to origin"
  git push --quiet -u origin "$BRANCH"
  git push --quiet origin "refs/tags/$TAG"
else
  warn "no 'origin' remote: the commit and tag $TAG stay local"
fi

# ---------------------------------------------------------------------------
# Publish. Each target is tried even if an earlier one fails.
# ---------------------------------------------------------------------------
FAILED=""
SUCCEEDED=""

if [ "$SKIP_GITHUB" = 0 ]; then
  step "GitHub release $TAG"
  if gh release view "$TAG" >/dev/null 2>&1; then
    if gh release upload "$TAG" "$VSIX" --clobber; then SUCCEEDED="$SUCCEEDED github"; else FAILED="$FAILED github"; fi
  else
    gh_args=(release create "$TAG" "$VSIX" --verify-tag --title "$TAG")
    [ "$PRE_RELEASE" = 0 ] || gh_args+=(--prerelease)
    if [ -n "$NOTES" ]; then gh_args+=(--notes "$NOTES"); else gh_args+=(--generate-notes); fi
    if gh "${gh_args[@]}"; then SUCCEEDED="$SUCCEEDED github"; else FAILED="$FAILED github"; fi
  fi
fi

if [ "$SKIP_MARKETPLACE" = 0 ]; then
  step "VS Code Marketplace"
  vsce_args=(publish --packagePath "$VSIX" --skip-duplicate)
  [ "$PRE_RELEASE" = 0 ] || vsce_args+=(--pre-release)
  # Without --oidc, vsce reads VSCE_PAT from the environment.
  [ "$OIDC" = 0 ] || vsce_args+=(--oidc)
  if npx --no -- vsce "${vsce_args[@]}"; then SUCCEEDED="$SUCCEEDED marketplace"; else FAILED="$FAILED marketplace"; fi
fi

if [ "$SKIP_OPENVSX" = 0 ]; then
  step "Open VSX"
  # ovsx reads OVSX_PAT from the environment, or uses trusted publishing on GitHub Actions
  # when no token is set. The pre-release flag is already inside the .vsix.
  if npx --no -- ovsx publish "$VSIX" --skip-duplicate; then SUCCEEDED="$SUCCEEDED openvsx"; else FAILED="$FAILED openvsx"; fi
fi

echo
case "$SUCCEEDED" in *github*)
  echo "GitHub:      $(gh release view "$TAG" --json url --jq .url 2>/dev/null || echo "release $TAG")" ;;
esac
case "$SUCCEEDED" in *marketplace*)
  echo "Marketplace: https://marketplace.visualstudio.com/items?itemName=$PUBLISHER.$NAME (can take a few minutes to update)" ;;
esac
case "$SUCCEEDED" in *openvsx*)
  echo "Open VSX:    https://open-vsx.org/extension/$PUBLISHER/$NAME" ;;
esac

if [ -n "$FAILED" ]; then
  # Skip what already worked when retrying.
  case "$SUCCEEDED" in *github*) SKIP_GITHUB=1 ;; esac
  case "$SUCCEEDED" in *marketplace*) SKIP_MARKETPLACE=1 ;; esac
  case "$SUCCEEDED" in *openvsx*) SKIP_OPENVSX=1 ;; esac
  echo >&2
  echo "Failed:$FAILED. Fix the problem above, then finish with:" >&2
  echo "  $(resume_command)" >&2
  trap - EXIT
  exit 1
fi

echo
echo "Released $NAME $VERSION."
