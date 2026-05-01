# apt-packages

APT repository for [vmvarela](https://github.com/vmvarela) tools, served via GitHub Pages.

## Installation

```bash
curl -sSL https://vmvarela.github.io/apt-packages/key.gpg \
  | sudo tee /etc/apt/keyrings/vmvarela.asc
echo "deb [signed-by=/etc/apt/keyrings/vmvarela.asc] https://vmvarela.github.io/apt-packages stable main" \
  | sudo tee /etc/apt/sources.list.d/vmvarela.list
sudo apt update && sudo apt install sql-pipe
```

## Packages

| Package | Description |
|---------|-------------|
| [sql-pipe](https://github.com/vmvarela/sql-pipe) | Read CSV from stdin, query with SQL, write CSV to stdout |

## Required Secrets

| Secret | Description |
|--------|-------------|
| `GPG_SIGNING_KEY` | GPG private key (armored) for signing the repository |
| `GPG_KEY_ID` | Key ID or fingerprint matching `GPG_SIGNING_KEY` |

If secrets are not set the repository is built but left unsigned (install will require `--allow-unauthenticated`).
