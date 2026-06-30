import? 'justfile.project'
import? 'justfile.local'

default:
  @just --list

help:
  @just --list

# ── Setup ─────────────────────────────────────────────────────────────────────

[group('setup')]
setup:
  @echo "[INFO] Setup"
  @just setup-devcontainer

[group('setup')]
setup-devcontainer:
  @.devcontainer/scripts/setup-devcontainer.sh

# ── Auth ──────────────────────────────────────────────────────────────────────

[group('auth')]
gh-login:
  @gh auth login

[group('auth')]
claude-login:
  @claude auth login

# ── Tools ─────────────────────────────────────────────────────────────────────

[group('tools')]
pre-commit-run:
  @pre-commit run --all-files

[group('tools')]
vscode-dev-setup-cli *args:
  @./vscode-dev-setup-cli.sh {{ args }}

[group('tools')]
scaffold-ai-cli *args:
  @curl -fsSL https://raw.githubusercontent.com/FabrizioCafolla/scaffold-ai/main/cli.sh | bash -s -- {{args}}
