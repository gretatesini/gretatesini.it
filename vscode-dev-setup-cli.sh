#!/usr/bin/env bash
# vscode-dev-setup-cli.sh — check and update vscode-dev-setup template files
#
# Usage:
#   ./vscode-dev-setup-cli.sh <command> [OPTIONS]
#   curl -fsSL https://raw.githubusercontent.com/FabrizioCafolla/vscode-dev-setup/main/vscode-dev-setup-cli.sh | bash -s -- <command> [OPTIONS]
#
# Commands:
#   check     Show what would change (no modifications)
#   update    Apply base file updates
#
# Options:
#   --ref REF          Git ref to use (default: main)
#   --force            Force-replace DIFF-ONLY files (devcontainer.json)
#   --workspace DIR    Target workspace (default: current dir)
#   -h, --help         Show help

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

# ── Argument parsing ──────────────────────────────────────────────────────────

COMMAND=""
GIT_REF="main"
FORCE=false
WORKSPACE_DIR="$(pwd)"

usage() {
  cat <<EOF
Usage: vscode-dev-setup-cli.sh <command> [OPTIONS]

Commands:
  check     Show what would change (no modifications)
  update    Apply base file updates

Options:
  --ref REF          Git ref to use (default: main)
  --force            Force-replace DIFF-ONLY files (devcontainer.json)
  --workspace DIR    Target workspace (default: current dir)
  -h, --help         Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    check|update)
      COMMAND="$1"
      shift
      ;;
    --ref)
      GIT_REF="$2"
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --workspace)
      WORKSPACE_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$COMMAND" ]]; then
  echo "Error: command required (check|update)" >&2
  usage >&2
  exit 1
fi

# ── Dependency check ──────────────────────────────────────────────────────────

for dep in bash git diff; do
  if ! command -v "$dep" &>/dev/null; then
    echo "Error: required dependency not found: $dep" >&2
    exit 1
  fi
done

# ── Workspace validation ──────────────────────────────────────────────────────

if [[ ! -d "${WORKSPACE_DIR}/.devcontainer" ]]; then
  if [[ $FORCE == true ]]; then
    echo -e "${YELLOW}WARNING:${RESET} .devcontainer/ not found in ${WORKSPACE_DIR}, but --force is set. Proceeding anyway."
    mkdir -p "${WORKSPACE_DIR}/.devcontainer"
    echo ""
  else
    echo "Error: .devcontainer/ not found in ${WORKSPACE_DIR}" >&2
    echo "Run from your project root or use --workspace DIR" >&2
    exit 1
  fi
fi

echo -e "${CYAN}${BOLD}vscode-dev-setup ${COMMAND}${RESET} (ref: ${GIT_REF})"
echo ""

# ── Clone template ────────────────────────────────────────────────────────────

REPO_URL="https://github.com/FabrizioCafolla/vscode-dev-setup.git"
TEMP_DIR="$(mktemp -d)"
TEMPLATE_DIR="${TEMP_DIR}/vscode-dev-setup"

cleanup() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

echo "Fetching template (ref: ${GIT_REF})..."
git clone --quiet --depth 1 --branch "${GIT_REF}" "${REPO_URL}" "${TEMPLATE_DIR}" 2>&1 \
  || { echo -e "${RED}Error: failed to clone template${RESET}" >&2; exit 1; }

TEMPLATE_SHA="$(git -C "${TEMPLATE_DIR}" rev-parse HEAD)"
echo -e "Template commit: ${TEMPLATE_SHA}"
echo ""

# ── Counters ──────────────────────────────────────────────────────────────────

updated=0
created=0
skipped=0
manual=0
changes=0  # tracks changes found in check mode

# ── Helper functions ──────────────────────────────────────────────────────────

show_diff() {
  local label="$1" local_file="$2" template_file="$3"
  echo -e "${BOLD}── ${label} ──────────────────────────────────────────────────────────${RESET}"
  diff --unified=3 --label "local" --label "template (${GIT_REF})" \
    "${local_file}" "${template_file}" | head -80 || true
  echo ""
}

show_block_diff() {
  local label="$1" local_block="$2" template_block="$3"
  echo -e "${BOLD}── ${label} ──────────────────────────────────────────────────────────${RESET}"
  diff --unified=3 --label "local" --label "template (${GIT_REF})" \
    <(echo "${local_block}") <(echo "${template_block}") | head -80 || true
  echo ""
}

extract_marker_block() {
  local file="$1" start_marker="$2" end_marker="$3"
  awk "/${start_marker}/{found=1; next} /${end_marker}/{found=0} found" "${file}"
}

replace_marker_block() {
  local file="$1" start_marker="$2" end_marker="$3" new_block="$4"
  local before after result
  before="$(mktemp)"
  after="$(mktemp)"
  result="$(mktemp)"

  # Extract everything up to and including START marker line
  awk "/${start_marker}/{print; exit} {print}" "${file}" > "${before}"

  # Extract everything from END marker line onwards
  awk "/${end_marker}/{found=1} found{print}" "${file}" > "${after}"

  # Combine: before + new block + after
  cat "${before}" > "${result}"
  echo "${new_block}" >> "${result}"
  cat "${after}" >> "${result}"

  mv "${result}" "${file}"
  rm -f "${before}" "${after}"
}

# ── REPLACE files ─────────────────────────────────────────────────────────────

process_replace() {
  local rel_path="$1"
  local local_file="${WORKSPACE_DIR}/${rel_path}"
  local template_file="${TEMPLATE_DIR}/${rel_path}"

  if [[ ! -f "${template_file}" ]]; then
    echo -e "${YELLOW}SKIP${RESET}    ${rel_path} (not in template)"
    return
  fi

  if [[ ! -f "${local_file}" ]]; then
    echo -e "${YELLOW}MISSING${RESET} ${rel_path}"
    (( changes++ )) || true
    if [[ "${COMMAND}" == "update" ]]; then
      mkdir -p "$(dirname "${local_file}")"
      cp "${template_file}" "${local_file}"
      echo -e "${GREEN}CREATED${RESET} ${rel_path}"
      (( updated++ )) || true
    fi
    return
  fi

  if diff --brief "${local_file}" "${template_file}" &>/dev/null; then
    echo -e "·       ${rel_path} (up to date)"
    (( skipped++ )) || true
    return
  fi

  echo -e "${YELLOW}CHANGED${RESET} ${rel_path}"
  (( changes++ )) || true
  show_diff "${rel_path}" "${local_file}" "${template_file}"

  if [[ "${COMMAND}" == "update" ]]; then
    cp "${template_file}" "${local_file}"
    echo -e "${GREEN}UPDATED${RESET} ${rel_path}"
    (( updated++ )) || true
  fi
}

echo -e "${BOLD}REPLACE files (fully template-managed)${RESET}"
process_replace ".devcontainer/docker-compose.yml"
process_replace ".devcontainer/scripts/setup-devcontainer.sh"
process_replace "justfile"
process_replace "vscode-dev-setup-cli.sh"
echo ""

# ── MARKER files ──────────────────────────────────────────────────────────────

process_marker() {
  local rel_path="$1" start_marker="$2" end_marker="$3"
  local local_file="${WORKSPACE_DIR}/${rel_path}"
  local template_file="${TEMPLATE_DIR}/${rel_path}"

  if [[ ! -f "${template_file}" ]]; then
    echo -e "${YELLOW}SKIP${RESET}    ${rel_path} (not in template)"
    return
  fi

  local template_block
  template_block="$(extract_marker_block "${template_file}" "${start_marker}" "${end_marker}")"

  if [[ ! -f "${local_file}" ]]; then
    echo -e "${YELLOW}MISSING${RESET} ${rel_path}"
    (( changes++ )) || true
    if [[ "${COMMAND}" == "update" ]]; then
      cp "${template_file}" "${local_file}"
      echo -e "${GREEN}CREATED${RESET} ${rel_path} (from template)"
      (( updated++ )) || true
    fi
    return
  fi

  if ! grep -q "${start_marker}" "${local_file}"; then
    echo -e "${YELLOW}NO MARKERS${RESET} ${rel_path} add ${start_marker} / ${end_marker} markers manually"
    (( changes++ )) || true
    (( manual++ )) || true
    return
  fi

  local local_block
  local_block="$(extract_marker_block "${local_file}" "${start_marker}" "${end_marker}")"

  if [[ "${local_block}" == "${template_block}" ]]; then
    echo -e "·       ${rel_path} (up to date)"
    (( skipped++ )) || true
    return
  fi

  echo -e "${YELLOW}CHANGED${RESET} ${rel_path} (template block)"
  (( changes++ )) || true
  show_block_diff "${rel_path}" "${local_block}" "${template_block}"

  if [[ "${COMMAND}" == "update" ]]; then
    replace_marker_block "${local_file}" "${start_marker}" "${end_marker}" "${template_block}"
    echo -e "${GREEN}UPDATED${RESET} ${rel_path} (template block only)"
    (( updated++ )) || true
  fi
}

echo -e "${BOLD}MARKER files (partial template sections)${RESET}"
process_marker "AGENTS.md" "\[vscode-dev-setup:START\]" "\[vscode-dev-setup:END\]"
process_marker ".pre-commit-config.yaml" "\[vscode-dev-setup:START\]" "\[vscode-dev-setup:END\]"
process_marker ".gitignore" "\[vscode-dev-setup:START\]" "\[vscode-dev-setup:END\]"
process_marker ".devcontainer/Dockerfile" "\[vscode-dev-setup:START\]" "\[vscode-dev-setup:END\]"
process_marker ".devcontainer/configs/.zshrc" "\[vscode-dev-setup:START\]" "\[vscode-dev-setup:END\]"
echo ""

# ── DIFF-ONLY files ───────────────────────────────────────────────────────────

process_diff_only() {
  local rel_path="$1"
  local local_file="${WORKSPACE_DIR}/${rel_path}"
  local template_file="${TEMPLATE_DIR}/${rel_path}"

  if [[ ! -f "${template_file}" ]]; then
    echo -e "${YELLOW}SKIP${RESET}    ${rel_path} (not in template)"
    return
  fi

  if [[ ! -f "${local_file}" ]]; then
    echo -e "${YELLOW}MISSING${RESET} ${rel_path}"
    (( changes++ )) || true
    if [[ "${COMMAND}" == "update" ]]; then
      mkdir -p "$(dirname "${local_file}")"
      cp "${template_file}" "${local_file}"
      echo -e "${GREEN}CREATED${RESET} ${rel_path}"
      (( updated++ )) || true
    fi
    return
  fi

  if diff --brief "${local_file}" "${template_file}" &>/dev/null; then
    echo -e "·       ${rel_path} (up to date)"
    (( skipped++ )) || true
    return
  fi

  echo -e "${YELLOW}CHANGED${RESET} ${rel_path}"
  (( changes++ )) || true
  show_diff "${rel_path}" "${local_file}" "${template_file}"

  if [[ "${COMMAND}" == "update" ]]; then
    if [[ "${FORCE}" == "true" ]]; then
      cp "${template_file}" "${local_file}"
      echo -e "${GREEN}FORCE-UPDATED${RESET} ${rel_path}"
      (( updated++ )) || true
    else
      echo -e "${CYAN}→ Review the diff above and apply manually. Use --force to overwrite.${RESET}"
      (( manual++ )) || true
    fi
  fi
}

echo -e "${BOLD}DIFF-ONLY files (manual review required)${RESET}"
process_diff_only ".devcontainer/devcontainer.json"
echo ""

# ── NEVER-TOUCH files ─────────────────────────────────────────────────────────

process_never_touch() {
  local rel_path="$1"
  local local_file="${WORKSPACE_DIR}/${rel_path}"
  local template_file="${TEMPLATE_DIR}/${rel_path}"

  if [[ -f "${local_file}" ]]; then
    return  # exists never overwrite, skip silently
  fi

  if [[ "${COMMAND}" == "check" ]]; then
    echo -e "${CYAN}WILL CREATE${RESET} ${rel_path} (does not exist)"
    (( changes++ )) || true
    return
  fi

  if [[ -f "${template_file}" ]]; then
    mkdir -p "$(dirname "${local_file}")"
    cp "${template_file}" "${local_file}"
  else
    mkdir -p "$(dirname "${local_file}")"
    touch "${local_file}"
  fi
  echo -e "${GREEN}CREATED${RESET} ${rel_path}"
  (( created++ )) || true
}

# ── CLEANUP: deprecated files removed between releases ────────────────────────

DEPRECATED_FILES=(
  ".devcontainer/scripts/load-env.sh"
  ".devcontainer/configs/.env.local"
  "update-devcontainer.sh"
)

if [[ "${COMMAND}" == "update" ]]; then
  echo -e "${BOLD}CLEANUP deprecated files${RESET}"
  _any_removed=false
  for _file in "${DEPRECATED_FILES[@]}"; do
    if [[ -f "${WORKSPACE_DIR}/${_file}" ]]; then
      rm "${WORKSPACE_DIR}/${_file}"
      echo -e "${GREEN}REMOVED${RESET} ${_file}"
      (( updated++ )) || true
      _any_removed=true
    fi
  done
  [[ "${_any_removed}" == false ]] && echo -e "·       nothing to remove"
  echo ""
fi

# ── NEVER-TOUCH files (created once, never overwritten) ───────────────────────

echo -e "${BOLD}NEVER-TOUCH files (created once, never overwritten)${RESET}"
process_never_touch ".devcontainer/docker-compose.project.yml"
process_never_touch ".devcontainer/docker-compose.local.yml"
process_never_touch ".devcontainer/scripts/setup-devcontainer.project.sh"
process_never_touch ".devcontainer/scripts/setup-devcontainer.local.sh"
process_never_touch ".env.project"
process_never_touch "justfile.project"
process_never_touch "justfile.local"
process_never_touch "README.md"
# Auto-discover .gitignore files in configs/ and cache/ from template
while IFS= read -r -d '' _gi; do
  process_never_touch "${_gi#"${TEMPLATE_DIR}"/}"
done < <(find "${TEMPLATE_DIR}/.devcontainer/configs" "${TEMPLATE_DIR}/.devcontainer/cache" -name '.gitignore' -print0 2>/dev/null | sort -z)
echo ""

# ── Lockfile ──────────────────────────────────────────────────────────────────

if [[ "${COMMAND}" == "update" ]]; then
  echo "${TEMPLATE_SHA}" > "${WORKSPACE_DIR}/.vscode-dev-setup.lock"
  echo -e "${GREEN}LOCKED${RESET}  .vscode-dev-setup.lock (${TEMPLATE_SHA})"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}vscode-dev-setup ${COMMAND} complete${RESET}"
echo ""
if (( updated > 0 )); then
  echo -e "  ${GREEN}✓${RESET} ${updated} file(s) updated"
fi
if (( created > 0 )); then
  echo -e "  ${GREEN}+${RESET} ${created} file(s) created"
fi
if (( skipped > 0 )); then
  echo -e "  · ${skipped} file(s) already up to date"
fi
if (( manual > 0 )); then
  echo -e "  ${YELLOW}→${RESET} ${manual} file(s) need manual review (see above)"
fi
if (( changes > 0 )) && [[ "${COMMAND}" == "check" ]]; then
  echo ""
  echo -e "  Run ${CYAN}update${RESET} to apply changes."
fi

# Exit 1 if there are changes available (useful for CI)
if [[ "${COMMAND}" == "check" ]] && (( changes > 0 )); then
  exit 1
fi
