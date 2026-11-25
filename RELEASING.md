# Releasing

How to build a `.vsix` and publish a new version to **GitHub Releases**, the **VS Code Marketplace** and **Open VSX**.

Every script has a Bash (`.sh`, Linux / macOS / Git Bash) and a PowerShell (`.ps1`, Windows / PowerShell 7) version that do the same thing.

| Script | What it does |
| --- | --- |
| `scripts/package.sh` / `scripts/package.ps1` | Builds `releases/<name>-<version>.vsix` from the current version. Changes nothing else. |
| `scripts/publish.sh` / `scripts/publish.ps1` | Bumps the version, updates the changelog, builds the `.vsix`, commits, tags, pushes, and publishes to all three places. |
| **Release** workflow (GitHub Actions) | Runs `scripts/publish.sh` on GitHub, started with a button. The recommended way to publish to the Marketplace (see below). |

Requires **Node.js 22 or later** (`.nvmrc`): the packaging tools (`@vscode/vsce` 4, `ovsx` 1.4) need it.

## Build a .vsix only

```bash
./scripts/package.sh                 # releases/where-was-i-<version>.vsix
./scripts/package.sh --pre-release
```

```powershell
./scripts/package.ps1
./scripts/package.ps1 -PreRelease
```

Install it with `code --install-extension releases/where-was-i-<version>.vsix` to try it before publishing.

## Publish a new version

1. Add your changes under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) and commit everything.
2. Run the publish script (or the Release workflow, see below) with the kind of version bump you want:

```bash
./scripts/publish.sh patch --dry-run   # try it: builds the .vsix, publishes nothing, undoes the version change
./scripts/publish.sh patch             # 0.1.0 -> 0.1.1
./scripts/publish.sh minor             # 0.1.0 -> 0.2.0
./scripts/publish.sh major             # 0.1.0 -> 1.0.0
./scripts/publish.sh 1.4.0             # an exact version
./scripts/publish.sh minor --pre-release
./scripts/publish.sh patch --skip-marketplace --skip-openvsx   # GitHub release only
```

```powershell
./scripts/publish.ps1 patch -DryRun
./scripts/publish.ps1 minor
./scripts/publish.ps1 1.4.0 -PreRelease
./scripts/publish.ps1 patch -SkipMarketplace -SkipOpenVsx
```

If PowerShell refuses to run the script, start it with `powershell -ExecutionPolicy Bypass -File scripts\publish.ps1 minor`.

Version `0.0.1` is already published, so the next `minor` release is `0.1.0`.

### What the publish script does

1. Checks: clean working tree, on a branch, not behind `origin`, the new tag doesn't exist yet, credentials are present. Then shows the plan and asks to continue (`--yes` / `-Yes` skips the question).
2. `npm ci`, then sets the new version in `package.json` and `package-lock.json`.
3. In `CHANGELOG.md`, moves the notes under `## [Unreleased]` to a new `## [X.Y.Z] - date` heading.
4. Builds `releases/<name>-X.Y.Z.vsix` with the package script (type-check, lint, production bundle).
5. Commits `chore(release): vX.Y.Z`, creates the tag `vX.Y.Z`, and pushes both to `origin`.
6. Creates the GitHub release `vX.Y.Z` with the changelog notes and the `.vsix` attached.
7. Publishes the same `.vsix` to the VS Code Marketplace and to Open VSX.

If anything fails before the commit, the version and changelog changes are undone. Each publish target in steps 6–7 is tried even if an earlier one failed.

### When a publish step fails

The script prints the command that finishes the release, for example:

```bash
./scripts/publish.sh current --skip-github
```

`current` releases the version already in `package.json` without bumping it. It reuses the existing tag, and targets that already have this version are skipped, so running it again is safe.

## Versions

- Only `X.Y.Z`. The Marketplace rejects suffixes such as `1.0.0-beta`; use `--pre-release` instead.
- A pre-release and a release can't share a version number. VS Code recommends **even minor numbers for releases and odd minor numbers for pre-releases** (e.g. `0.2.x` release, `0.3.x` pre-release).
- The Marketplace never accepts the same version twice, so every published build needs a new version.

## One-time setup

### 1. GitHub

The repository is `Rajan694/Git-Commit-Code-Visualizer`, with `origin` pointing at it. Log in the GitHub CLI once:

```bash
gh auth login
```

### 2. VS Code Marketplace

The publisher is `rajan694` (the `publisher` field in `package.json`). Create it at <https://marketplace.visualstudio.com/manage> if it doesn't exist yet.

**Important:** Azure DevOps retires global personal access tokens on **1 December 2026**. A Marketplace `VSCE_PAT` has to be global ("All accessible organizations"), so after that date it stops working. Microsoft's recommended replacement is **Trusted Publishing** from GitHub Actions, which needs no token at all:

1. Push the repository to GitHub (the `release.yml` workflow must be on `main`).
2. Open <https://marketplace.visualstudio.com/manage>, choose the publisher, select **Trusted Publishing**, expand **Create** and fill in:
   - Policy name: `Release workflow`
   - Repository owner: `Rajan694`
   - Repository: `Git-Commit-Code-Visualizer`
   - Workflow: `release.yml`
   - Environment: leave empty
3. For a private repository, run the Release workflow within 48 hours; the first successful publish activates the policy permanently.

From then on, publish with the **Release** workflow (next section). The workflow runs the same `publish.sh`, which detects GitHub's OIDC token and calls `vsce publish --oidc`.

*Until 1 December 2026 only:* local publishing to the Marketplace still works with a global PAT. In Azure DevOps choose **User settings → Personal access tokens → New Token**, Organization **All accessible organizations**, Scopes **Custom defined → Marketplace → Manage**, and save it as `VSCE_PAT` (step 4).

### 3. Open VSX

The namespace `rajan694` exists and is owned, and `where-was-i` 0.0.1 is already on Open VSX, so the Release workflow can use trusted publishing from the start, without a token:

1. Open <https://open-vsx.org/user-settings/trusted-publishers>, choose namespace `rajan694`, extension `where-was-i` and provider **GitHub Actions**, and fill in:
   - Organization or User name: `Rajan694`
   - Repository name: `Git-Commit-Code-Visualizer`
   - Workflow filename: `release.yml`
   - Environment name: leave empty
2. Don't add an `OVSX_PAT` repository secret: an access token always takes precedence over trusted publishing. If one exists, remove it with `gh secret delete OVSX_PAT`.

The workflow then publishes with a short-lived token that `ovsx` gets in exchange for GitHub's OIDC token (the workflow has `id-token: write`). If it fails with *No trusted publisher matches the presented token*, check the names in the registration: they are compared exactly, including case.

Publishing from your own machine still needs an access token from <https://open-vsx.org/user-settings/tokens> as `OVSX_PAT` in `.env` (step 4).

### 4. Local tokens

Copy `.env.example` to `.env` and fill in `OVSX_PAT` (and `VSCE_PAT` if you still have a valid one). `.env` is git-ignored and never packaged. Values already set in your environment take precedence.

## Publish from GitHub (Release workflow)

**Actions → Release → Run workflow**, then pick the version (`patch`, `minor`, `major`, `X.Y.Z` or `current`), whether it's a pre-release, and which targets to publish to. Or from a terminal:

```bash
gh workflow run release.yml -f version=minor
gh run watch
```

The workflow commits the version bump and tag to `main` as `github-actions[bot]`, so run `git pull` afterwards. It runs only on `main`.

The **CI** workflow runs on every push and pull request: type-check, lint, tests on Linux, macOS and Windows, and both package scripts. The built `.vsix` is attached to each run as the `vsix` artifact.
