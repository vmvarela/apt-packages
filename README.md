# apt-packages

APT repository for [vmvarela](https://github.com/vmvarela) tools, served via GitHub Pages.

## Installation

```bash
curl -sSL https://vmvarela.github.io/apt-packages/key.gpg \
  | sudo tee /etc/apt/keyrings/vmvarela.asc
echo "deb [signed-by=/etc/apt/keyrings/vmvarela.asc] https://vmvarela.github.io/apt-packages stable main" \
  | sudo tee /etc/apt/sources.list.d/vmvarela.list
sudo apt update && sudo apt install sql-pipe
sudo apt install ghoten
```

## Packages

| Package | Description |
|---------|-------------|
| [sql-pipe](https://github.com/vmvarela/sql-pipe) | Read CSV from stdin, query with SQL, write CSV to stdout |
| [ghoten](https://github.com/vmvarela/ghoten) | Reproducible OpenTofu distribution with Smart Refresh and an ORAS backend for OCI state |
| [damas](https://github.com/vmvarela/damas) | Local-first task board for the terminal |

## Durable state and shadow check

`state/<package>/state.json` (schema_version 1) and `state/<package>/pool/<file>.deb` hold the retained packages for the contract in `docs/receivers.md` section 3a of vmvarela/package-distribution (merged as 8cbe59b): at most two entries per architecture, newest first, each with `version`, `sha256` and `file`. The state was bootstrapped from the live site and the GitHub releases, and the SHA-256 of every `.deb` matches the release `sha256sums.txt`.

- `update.yml` builds the site with the shared `apt-publish.mjs` from `vmvarela/package-distribution`, pinned by `PACKAGE_DISTRIBUTION_SHA`. It resolves the requested or latest stable release for `sql-pipe`, `ghoten` or `damas`, publishes from the GitHub release assets, and deploys to Pages only when the state changes. A no-op version deploys nothing.
- After a successful deployment the workflow copies the candidate state over `state/` and commits it, so the next run rebuilds every package from the recorded state. Promotion order is verify, deploy, then state.
- `shadow-state.yml` is a manual (`workflow_dispatch`) check. It builds a candidate site from `state/` with `apt-publish.mjs --shadow`, compares it with the live site using `apt-compare.mjs`, and uploads the result as an artifact. It never deploys to Pages and never writes `state/`. It runs the `package-distribution` checkout pinned by `PACKAGE_DISTRIBUTION_SHA`; update that pin when the contract changes.
- The shadow check needs `GPG_SIGNING_KEY` and `GPG_KEY_ID` to sign the candidate, the same secrets as `update.yml`.
- When the requested release equals the state, the publisher reports `noop` and there is no candidate to compare.

## Required Secrets

| Secret | Description |
|--------|-------------|
| `GPG_SIGNING_KEY` | GPG private key (armored) for signing the repository |
| `GPG_KEY_ID` | Key ID or fingerprint matching `GPG_SIGNING_KEY` |

Release metadata and the durable state commit use the workflow's
repository-scoped `GITHUB_TOKEN` (`contents: write`). Local runs work
unauthenticated; export `GH_TOKEN` to authenticate and avoid GitHub API rate
limits.

If `GPG_SIGNING_KEY`/`GPG_KEY_ID` are not set, the build fails and the previously deployed repository remains untouched.
