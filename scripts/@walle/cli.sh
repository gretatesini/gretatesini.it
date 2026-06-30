#!/usr/bin/env bash
#
# Walle CLI v2. Scaffolds/updates a consumer from the curated template/ and syncs the declared
# modules' @walle paths — from a release tag (default: latest published tag, never main) or a local
# source (--source, dev/test). Supports --dry-run, `add <module>`, and `walle check`.

set -Ee
set -o pipefail
set -o functrace

INTENTIONAL_EXIT=0
DRY_RUN=0
ASSUME_YES=0
# 1 during init/add (seeds are written if absent); 0 during update (seeds untouched).
SEED_ENABLED=0
# 1 to seed .devcontainer/ at init (default); 0 to skip (--no-devcontainer).
DEVCONTAINER_ENABLED=1
# Active modules for the generated AGENTS.md block (set by init/update/add before syncing).
AGENTS_MODULES=""
trap 'catch $? $LINENO ${BASH_SOURCE[0]}' EXIT
catch() {
  if [ "$1" != "0" ] && [ "${INTENTIONAL_EXIT}" != "1" ]; then
    echo "[ERROR] in $(basename "$3") at line $2 (error code $1)"
  fi
  if [ -n "${TEMP_DIR:-}" ] && [ -d "${TEMP_DIR}" ]; then
    rm -rf "${TEMP_DIR}"
  fi
}

GITHUB_WALLE_REPO="https://github.com/FabrizioCafolla/walle-design-system"
WALLE_START="<!-- [walle:START] -->"
WALLE_END="<!-- [walle:END] -->"
TEMP_DIR=""

print_info() { echo -e " [INFO] ${*}"; }
print_warn() { echo -e " [WARN] ${*}"; }
print_plan() { echo -e " [PLAN] ${*}"; }
print_error() {
  echo -e " [ERROR] ${*}"
  INTENTIONAL_EXIT=1
  exit 1
}

usage() {
  cat <<EOF
Usage: cli.sh <command> [options]

Commands:
  init      Scaffold a new consumer from template/ and sync the declared modules
  update    Re-sync the declared modules of an existing consumer
  add       Add a module to an existing consumer and sync it
  check     Validate a consumer (manifest, version pin, configs) — read-only; pass --source to diff managed paths, --verbose to list all modules and variants

Common options:
  -s, --source <path>         Use a local walle clone instead of a release (dev/test)
  -w, --walle-version <tag>   Release tag (e.g. v0.1.0-beta). Default: latest published tag (never main)
      --dry-run               Show the sync plan without writing anything (init/update/add)
      --yes                   Proceed across a MAJOR boundary without prompting (update)
      --no-devcontainer       Skip .devcontainer/ scaffold at init (default: seeded)
  -h, --help                  Show this help
EOF
}

# --- module contract ---------------------------------------------------------

validate_module() {
  case "$1" in
  website | ci | ai | backend | infrastructure | devcontainer) : ;;
  *) print_error "unknown module '$1'. Valid modules: website, ci, ai, backend, infrastructure, devcontainer" ;;
  esac
}

# 0 if SSR is enabled in the consumer's app.json, non-zero otherwise.
ssr_enabled() {
  node -e "try{const a=require('$1/src/configs/app.json');process.exit(a&&a.astro&&a.astro.ssr&&a.astro.ssr.enabled===true?0:1)}catch(e){process.exit(1)}" 2>/dev/null
}

# MANAGED paths: synced on every init/update/add (always overwritten). 'ai' has none —
# it is the AGENTS marker block, handled separately in sync_module.
module_managed_paths() {
  case "$1" in
  website) echo "src/@walle schemas scripts/@walle walle.justfile" ;;
  ci) echo ".github/workflows/actions/@walle" ;;
  ai) echo ".claude/skills/@walle" ;;
  backend) echo "" ;;
  infrastructure) echo "" ;;
  devcontainer) echo ".devcontainer/Dockerfile .devcontainer/docker-compose.yml .devcontainer/scripts/setup-devcontainer.sh .devcontainer/configs/.zshrc .devcontainer/configs/.aws/.gitignore" ;;
  esac
}

# SEED paths: consumer-owned files written at init/add only if absent, never touched by
# update. Source lives under seeds/<module>/<path>. Empty until a module ships scaffolding.
module_seed_paths() {
  case "$1" in
  website) echo "README.md justfile.project" ;;
  ci) echo ".github/workflows/test.yml .github/workflows/deploy.yml" ;;
  ai) echo "" ;;
  backend) echo "src/pages/api/health.ts src/pages/api/echo.ts src/middleware.ts" ;;
  infrastructure) echo "infrastructure/main.tf infrastructure/variables.tf infrastructure/providers.tf infrastructure/outputs.tf infrastructure/README.md infrastructure/.gitignore" ;;
  devcontainer) echo ".devcontainer/devcontainer.json .devcontainer/docker-compose.project.yml .devcontainer/scripts/setup-devcontainer.project.sh" ;;
  esac
}

# --- version / tag resolution ------------------------------------------------

# Latest published semver tag on the repo, never main. Empty if none. Prefers the latest
# stable release (vX.Y.Z); falls back to the latest prerelease (vX.Y.Z-pre) only when no
# stable tag exists. `sort -V` orders "vX.Y.Z" before "vX.Y.Z-pre", so a plain `tail -1`
# would wrongly rank a prerelease above its own stable release — hence the split.
resolve_latest_tag() {
  local tags
  tags="$(git ls-remote --tags --refs "$GITHUB_WALLE_REPO" 2>/dev/null |
    sed -n 's#.*refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*[-a-zA-Z0-9.]*\)$#\1#p' |
    sort -V)"
  [ -n "$tags" ] || return 0
  local stable
  stable="$(printf '%s\n' "$tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)"
  if [ -n "$stable" ]; then
    printf '%s\n' "$stable"
  else
    printf '%s\n' "$tags" | tail -1
  fi
}

# MAJOR component of a vX.Y.Z tag (empty for non-tags like "local").
major_of() {
  case "$1" in
  v[0-9]*) echo "${1#v}" | cut -d. -f1 ;;
  *) echo "" ;;
  esac
}

# Stop on a MAJOR increase unless --yes. No-op when either side is not a tag (e.g. local).
check_major_jump() {
  local current="$1" target="$2"
  local cm tm
  cm="$(major_of "$current")"
  tm="$(major_of "$target")"
  [ -n "$cm" ] && [ -n "$tm" ] || return 0
  if [ "$tm" -gt "$cm" ]; then
    if [ "$ASSUME_YES" = "1" ]; then
      print_warn "Crossing a MAJOR boundary (${current} -> ${target}). Review the migration notes in CHANGELOG.md."
    else
      print_error "Update ${current} -> ${target} crosses a MAJOR boundary (breaking changes). Review the migration notes in CHANGELOG.md, then re-run with --yes to proceed."
    fi
  fi
}

# --- sync primitives ---------------------------------------------------------

sync_path() {
  local source_path="$1" target_path="$2"
  if [ -d "$source_path" ]; then
    rm -rf "$target_path"
    mkdir -p "$(dirname "$target_path")"
    cp -r "$source_path" "$target_path"
  elif [ -f "$source_path" ]; then
    mkdir -p "$(dirname "$target_path")"
    cp "$source_path" "$target_path"
  fi
}

# Print the +/~/- plan for a path without writing (dry-run).
plan_path() {
  local src="$1" dst="$2" f rel
  [ -e "$src" ] || return 0
  if [ -d "$src" ]; then
    while IFS= read -r f; do
      rel="${f#"$src"/}"
      if [ ! -e "${dst}/${rel}" ]; then
        print_plan "+ ${dst}/${rel}"
      elif ! cmp -s "$f" "${dst}/${rel}"; then
        print_plan "~ ${dst}/${rel}"
      fi
    done < <(find "$src" -type f)
    if [ -d "$dst" ]; then
      while IFS= read -r f; do
        rel="${f#"$dst"/}"
        # The LICENSE inside each @walle dir is managed/re-added by sync_module, not removed.
        case "$f" in *@walle/LICENSE) continue ;; esac
        [ -e "${src}/${rel}" ] || print_plan "- ${f}"
      done < <(find "$dst" -type f)
    fi
  elif [ -f "$src" ]; then
    if [ ! -e "$dst" ]; then
      print_plan "+ ${dst}"
    elif ! cmp -s "$src" "$dst"; then
      print_plan "~ ${dst}"
    fi
  fi
}

# Write a SEED path only if the target does NOT already exist. After the first write the
# consumer owns it: update never calls this, and add re-runs are no-ops on present seeds.
seed_path() {
  local source_path="$1" target_path="$2"
  [ -e "$source_path" ] || return 0
  if [ -e "$target_path" ]; then return 0; fi
  mkdir -p "$(dirname "$target_path")"
  if [ -d "$source_path" ]; then
    cp -r "$source_path" "$target_path"
  else
    cp "$source_path" "$target_path"
  fi
}

# Dry-run report for a SEED path: '+ (seed, once)' when absent, nothing when already present
# (a seed is never overwritten, so it never shows as ~ or -).
plan_seed_path() {
  local src="$1" dst="$2"
  [ -e "$src" ] || return 0
  if [ -e "$dst" ]; then return 0; fi
  print_plan "+ ${dst} (seed, once)"
}

# Sync BASE devcontainer files (MANAGED — overwritten on every update).
# Sourced from seeds/devcontainer/ because the repo's own .devcontainer/ is walle-specific.
# DRY_RUN-aware: calls plan_path instead of sync_path when DRY_RUN=1.
sync_devcontainer() {
  local source_dir="$1" target_dir="$2"
  [ "$DEVCONTAINER_ENABLED" = "1" ] || return 0
  for rel in $(module_managed_paths "devcontainer"); do
    if [ "$DRY_RUN" = "1" ]; then
      plan_path "${source_dir}/seeds/devcontainer/${rel}" "${target_dir}/${rel}"
    else
      sync_path "${source_dir}/seeds/devcontainer/${rel}" "${target_dir}/${rel}"
    fi
  done
}

# Seed PROJECT devcontainer files (write-once — only at init/add if absent).
# DRY_RUN-aware: calls plan_seed_path when DRY_RUN=1.
seed_devcontainer() {
  local source_dir="$1" target_dir="$2"
  [ "$DEVCONTAINER_ENABLED" = "1" ] || return 0
  for rel in $(module_seed_paths "devcontainer"); do
    if [ "$DRY_RUN" = "1" ]; then
      plan_seed_path "${source_dir}/seeds/devcontainer/${rel}" "${target_dir}/${rel}"
    else
      seed_path "${source_dir}/seeds/devcontainer/${rel}" "${target_dir}/${rel}"
    fi
  done
}

# One-line purpose of a module, used in the generated AGENTS.md module map.
module_purpose() {
  case "$1" in
  website) echo "Astro site — @walle components, layouts, styles, config and CLI scripts" ;;
  ci) echo "GitHub Actions workflows (test + deploy) under @walle" ;;
  ai) echo "AI harness — this generated AGENTS.md block and @walle skills" ;;
  backend) echo "API routes (requires SSR enabled in src/configs/app.json)" ;;
  infrastructure) echo "Terraform infrastructure under infrastructure/" ;;
  *) echo "walle module" ;;
  esac
}

# Emit the full walle-managed AGENTS.md block to stdout: curated preamble
# (scripts/@walle/agents.block.md) + a module map generated from the active
# modules ($AGENTS_MODULES) + how-to-work commands. The map makes the
# MANAGED (regenerated) vs SEED (consumer-owned) boundaries explicit per module.
generate_agents_block() {
  local source_dir="$1"
  local preamble="${source_dir}/scripts/@walle/agents.block.md"
  [ -f "$preamble" ] || print_error "missing AGENTS preamble source: ${preamble}"

  cat "$preamble"
  echo ""
  echo "### Active walle modules"
  echo ""
  local m managed seed
  for m in ${AGENTS_MODULES}; do
    echo "- **${m}** — $(module_purpose "$m")"
    managed="$(module_managed_paths "$m")"
    seed="$(module_seed_paths "$m")"
    [ -n "$managed" ] && echo "  - Managed (overwritten on update — never edit): $(echo "$managed" | sed 's/ /, /g')"
    [ -n "$seed" ] && echo "  - Seeded once (yours to own and edit): $(echo "$seed" | sed 's/ /, /g')"
  done
  echo ""
  echo "### Working with walle"
  echo ""
  echo "- Managed \`@walle/\` zones are regenerated by the walle CLI — edit the design system source, not these files."
  echo "- Update managed files to a new release: \`just walle-update\`."
  echo "- Add a module: run the walle CLI \`add <module>\` (then re-sync)."
  echo "- Validate the project: \`walle check\` (manifest v2, version pin, configs)."
  echo "- Develop / build the site: \`just dev\` / \`just build\`. Validate configs: \`just validate-configs\`."
}

# Rewrite the walle-managed block in AGENTS.md between the markers; append if absent.
# The block is generated (preamble + active-module map), not a static file.
sync_agents_marker() {
  local source_dir="$1" target_dir="$2"
  local target_file="${target_dir}/AGENTS.md"
  local block_file
  block_file="$(mktemp)"
  generate_agents_block "$source_dir" >"$block_file"

  if [ -f "$target_file" ] && grep -qF "$WALLE_START" "$target_file" && grep -qF "$WALLE_END" "$target_file"; then
    awk -v start="$WALLE_START" -v end="$WALLE_END" -v block="$block_file" '
      $0 == start { print; while ((getline line < block) > 0) print line; skip=1; next }
      $0 == end { print; skip=0; next }
      skip != 1 { print }
    ' "$target_file" >"${target_file}.tmp"
    mv "${target_file}.tmp" "$target_file"
    print_info "AGENTS.md walle block updated."
  else
    {
      [ -f "$target_file" ] && echo ""
      echo "$WALLE_START"
      cat "$block_file"
      echo "$WALLE_END"
    } >>"$target_file"
    print_info "AGENTS.md walle block appended."
  fi
  rm -f "$block_file"
}

# Dry-run report for the AGENTS marker block.
plan_agents_marker() {
  local source_dir="$1" target_dir="$2"
  local target_file="${target_dir}/AGENTS.md"
  local block_file
  block_file="$(mktemp)"
  generate_agents_block "$source_dir" >"$block_file"
  if [ ! -f "$target_file" ] || ! grep -qF "$WALLE_START" "$target_file"; then
    print_plan "+ ${target_file} (walle marker block appended)"
    rm -f "$block_file"
    return 0
  fi
  local current
  current="$(awk -v s="$WALLE_START" -v e="$WALLE_END" '$0==s{f=1;next} $0==e{f=0} f' "$target_file")"
  if ! diff -q <(printf '%s\n' "$current") "$block_file" >/dev/null 2>&1; then
    print_plan "~ ${target_file} (walle marker block content)"
  fi
  rm -f "$block_file"
}

sync_module() {
  local source_dir="$1" target_dir="$2" module="$3"
  # MANAGED paths: always synced (overwritten) on init/update/add.
  for rel in $(module_managed_paths "$module"); do
    if [ "$DRY_RUN" = "1" ]; then
      plan_path "${source_dir}/${rel}" "${target_dir}/${rel}"
    else
      sync_path "${source_dir}/${rel}" "${target_dir}/${rel}"
      if [ -d "${target_dir}/${rel}" ] && [[ "$rel" == *"@walle"* ]] && [ -f "${source_dir}/LICENSE" ]; then
        cp "${source_dir}/LICENSE" "${target_dir}/${rel}/LICENSE"
      fi
    fi
  done
  # SEED paths: written once (if absent) on init/add; skipped entirely on update.
  if [ "$SEED_ENABLED" = "1" ]; then
    for rel in $(module_seed_paths "$module"); do
      if [ "$DRY_RUN" = "1" ]; then
        plan_seed_path "${source_dir}/seeds/${module}/${rel}" "${target_dir}/${rel}"
      else
        seed_path "${source_dir}/seeds/${module}/${rel}" "${target_dir}/${rel}"
      fi
    done
  fi
  if [ "$module" = "ai" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      plan_agents_marker "$source_dir" "$target_dir"
    else
      sync_agents_marker "$source_dir" "$target_dir"
    fi
  fi
  [ "$DRY_RUN" = "1" ] || print_info "Module '${module}' synced."
}

# Resolve the walle source into SOURCE_DIR. Sets WALLE_VERSION and SOURCE_REF.
resolve_source() {
  local source_path="$1" version="$2"
  if [ -n "$source_path" ]; then
    [ -d "$source_path" ] || print_error "source path does not exist: ${source_path}"
    SOURCE_DIR="$(cd "$source_path" && pwd)"
    WALLE_VERSION="local"
    SOURCE_REF="$SOURCE_DIR"
    print_warn "Using local source ${SOURCE_DIR}: this project is NOT on a tagged release."
  else
    if [ -z "$version" ]; then
      version="$(resolve_latest_tag)"
      [ -n "$version" ] || print_error "no published release tags found. Use --walle-version <tag> or --source <path>."
      print_info "Resolved latest release tag: ${version}"
    fi
    TEMP_DIR="$(mktemp -d)"
    git clone --depth 1 -b "$version" "$GITHUB_WALLE_REPO" "$TEMP_DIR" &>/dev/null ||
      print_error "failed to clone ${GITHUB_WALLE_REPO} at ${version}"
    SOURCE_DIR="$TEMP_DIR"
    WALLE_VERSION="$version"
    SOURCE_REF=""
  fi
}

write_manifest() {
  local target_dir="$1" name="$2"
  shift 2
  local modules=("$@")
  local modules_json="" sep=""
  for m in "${modules[@]}"; do
    modules_json="${modules_json}${sep}\"${m}\""
    sep=", "
  done
  local source_ref_line=""
  if [ -n "${SOURCE_REF}" ]; then
    source_ref_line="  \"sourceRef\": \"${SOURCE_REF}\",
"
  fi
  local devcontainer_line="  \"devcontainer\": { \"enabled\": $([ "$DEVCONTAINER_ENABLED" = "1" ] && echo true || echo false) },"
  cat >"${target_dir}/.walle.config.json" <<EOF
{
  "\$schema": "./schemas/walle.config.schema.json",
  "schemaVersion": 2,
  "name": "${name}",
  "walleVersion": "${WALLE_VERSION}",
${source_ref_line}  "modules": [${modules_json}],
${devcontainer_line}
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  print_info "Manifest written: ${target_dir}/.walle.config.json"
}

# Read a manifest field via node (manifest path is absolute).
manifest_field() {
  node -e "const m=require('$1');process.stdout.write(String(m['$2']??''))" 2>/dev/null || true
}

# Read+validate a v2 manifest; sets MF_NAME and MF_MODULES (space-separated). Stops on v1.
read_manifest() {
  local manifest="$1"
  [ -f "$manifest" ] || print_error "no .walle.config.json found at ${manifest}"
  local sv
  sv="$(manifest_field "$manifest" schemaVersion)"
  [ "$sv" = "2" ] || print_error "manifest v1 detected (no schemaVersion: 2). Migration to v2 is required; see docs/migration-v1-to-v2.md. No files were changed."
  MF_NAME="$(manifest_field "$manifest" name)"
  MF_VERSION="$(manifest_field "$manifest" walleVersion)"
  MF_MODULES="$(node -e "const m=require('$manifest');process.stdout.write((m.modules||[]).join(' '))" 2>/dev/null)"
  [ -n "$MF_MODULES" ] || print_error "manifest declares no modules"
}

# --- commands ----------------------------------------------------------------

init() {
  local PROJECT_NAME="" DIR_PATH MODULES_CSV="website" SOURCE_PATH="" VERSION=""
  DIR_PATH="$(pwd)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -n | --project-name) PROJECT_NAME="$2"; shift 2 ;;
    -d | --dir-path) DIR_PATH="$2"; shift 2 ;;
    -m | --modules) MODULES_CSV="$2"; shift 2 ;;
    -s | --source) SOURCE_PATH="$2"; shift 2 ;;
    -w | --walle-version) VERSION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-devcontainer) DEVCONTAINER_ENABLED=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage; print_error "unknown option: $1" ;;
    esac
  done

  [ -n "$PROJECT_NAME" ] || print_error "project name is required (--project-name)"

  local modules=()
  IFS=',' read -ra modules <<<"$MODULES_CSV"
  local has_website=0
  for m in "${modules[@]}"; do
    validate_module "$m"
    [ "$m" = "website" ] && has_website=1
  done
  [ "$has_website" = "1" ] || print_error "'website' is a mandatory module"

  AGENTS_MODULES="${modules[*]}" # full active set for the generated AGENTS.md map
  SEED_ENABLED=1 # init writes module seeds (project is new)
  resolve_source "$SOURCE_PATH" "$VERSION"

  local project_dir="${DIR_PATH%/}/${PROJECT_NAME}"

  if [ "$DRY_RUN" = "1" ]; then
    print_plan "init plan for '${PROJECT_NAME}' (modules: ${MODULES_CSV}, version: ${WALLE_VERSION})"
    print_plan "+ ${project_dir}/ (scaffold from template/)"
    for m in "${modules[@]}"; do sync_module "$SOURCE_DIR" "$project_dir" "$m"; done
    sync_devcontainer "$SOURCE_DIR" "$project_dir"
    seed_devcontainer "$SOURCE_DIR" "$project_dir"
    print_info "Dry-run: no files written."
    return 0
  fi

  [ -e "$project_dir" ] && print_error "target already exists: ${project_dir}"
  mkdir -p "$project_dir"
  print_info "Scaffolding ${PROJECT_NAME} from template..."
  cp -a "${SOURCE_DIR}/template/." "$project_dir"/
  for m in "${modules[@]}"; do sync_module "$SOURCE_DIR" "$project_dir" "$m"; done
  sync_devcontainer "$SOURCE_DIR" "$project_dir"
  seed_devcontainer "$SOURCE_DIR" "$project_dir"
  write_manifest "$project_dir" "$PROJECT_NAME" "${modules[@]}"
  print_info "Project ${PROJECT_NAME} initialized in ${DIR_PATH}."
}

update() {
  local PROJECT_PATH SOURCE_PATH="" VERSION=""
  PROJECT_PATH="$(pwd)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -p | --project-path) PROJECT_PATH="$2"; shift 2 ;;
    -s | --source) SOURCE_PATH="$2"; shift 2 ;;
    -w | --walle-version) VERSION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage; print_error "unknown option: $1" ;;
    esac
  done

  read_manifest "${PROJECT_PATH}/.walle.config.json"
  local modules=()
  read -ra modules <<<"$MF_MODULES"
  for m in "${modules[@]}"; do validate_module "$m"; done
  AGENTS_MODULES="${modules[*]}" # full active set for the generated AGENTS.md map

  # Preserve devcontainer.enabled from the existing manifest.
  DEVCONTAINER_ENABLED=$(node -e "try{const m=require('${PROJECT_PATH}/.walle.config.json');process.stdout.write(m.devcontainer?.enabled!==false?'1':'0')}catch(e){process.stdout.write('1')}" 2>/dev/null || echo "1")

  resolve_source "$SOURCE_PATH" "$VERSION"
  check_major_jump "$MF_VERSION" "$WALLE_VERSION"

  if [ "$DRY_RUN" = "1" ]; then
    print_plan "update plan for '${MF_NAME}' (${MF_VERSION} -> ${WALLE_VERSION})"
    for m in "${modules[@]}"; do sync_module "$SOURCE_DIR" "$PROJECT_PATH" "$m"; done
    sync_devcontainer "$SOURCE_DIR" "$PROJECT_PATH"
    seed_devcontainer "$SOURCE_DIR" "$PROJECT_PATH"
    print_info "Dry-run: no files written."
    return 0
  fi

  print_info "Updating ${MF_NAME} (${PROJECT_PATH})..."
  for m in "${modules[@]}"; do sync_module "$SOURCE_DIR" "$PROJECT_PATH" "$m"; done
  sync_devcontainer "$SOURCE_DIR" "$PROJECT_PATH"
  seed_devcontainer "$SOURCE_DIR" "$PROJECT_PATH"
  write_manifest "$PROJECT_PATH" "$MF_NAME" "${modules[@]}"
  print_info "Project updated successfully."
}

add() {
  local PROJECT_PATH SOURCE_PATH="" VERSION="" NEW_MODULE=""
  PROJECT_PATH="$(pwd)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -p | --project-path) PROJECT_PATH="$2"; shift 2 ;;
    -s | --source) SOURCE_PATH="$2"; shift 2 ;;
    -w | --walle-version) VERSION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) usage; print_error "unknown option: $1" ;;
    *) NEW_MODULE="$1"; shift ;;
    esac
  done

  [ -n "$NEW_MODULE" ] || print_error "module name is required: cli.sh add <module>"
  validate_module "$NEW_MODULE"

  SEED_ENABLED=1 # add writes the new module's seeds if absent (re-add leaves them intact)

  read_manifest "${PROJECT_PATH}/.walle.config.json"
  local modules=()
  read -ra modules <<<"$MF_MODULES"

  local present=0 m
  for m in "${modules[@]}"; do [ "$m" = "$NEW_MODULE" ] && present=1; done
  [ "$present" = "1" ] && print_info "module '${NEW_MODULE}' already declared — re-syncing."

  resolve_source "$SOURCE_PATH" "$VERSION"

  if [ "$DRY_RUN" = "1" ]; then
    print_plan "add plan: module '${NEW_MODULE}' for '${MF_NAME}'"
    sync_module "$SOURCE_DIR" "$PROJECT_PATH" "$NEW_MODULE"
    print_info "Dry-run: no files written."
    return 0
  fi

  sync_module "$SOURCE_DIR" "$PROJECT_PATH" "$NEW_MODULE"
  [ "$present" = "1" ] || modules+=("$NEW_MODULE")
  write_manifest "$PROJECT_PATH" "$MF_NAME" "${modules[@]}"
  print_info "Module '${NEW_MODULE}' added to ${MF_NAME}."

  if [ "$NEW_MODULE" = "backend" ] && ! ssr_enabled "$PROJECT_PATH"; then
    print_warn "backend API routes require SSR — enable 'astro.ssr' in src/configs/app.json."
  fi
}

print_module_catalog() {
  echo ""
  echo "Available modules:"
  local m
  for m in website ci backend infrastructure ai; do
    local managed seed purpose
    managed="$(module_managed_paths "$m")"
    seed="$(module_seed_paths "$m")"
    purpose="$(module_purpose "$m")"
    local required=""
    [ "$m" = "website" ] && required=" (required)"
    echo "  ${m}${required} — ${purpose}"
    [ -n "$managed" ] && echo "    MANAGED : $(echo "$managed" | sed 's/ /, /g')"
    [ -n "$seed" ]    && echo "    SEED    : $(echo "$seed" | sed 's/ /, /g')"
  done
  echo ""
  echo "Available component variants:"
  echo "  navbar  : standard, minimal"
  echo "  footer  : standard, minimal"
}

check() {
  local PROJECT_PATH SOURCE_PATH="" VERBOSE=0
  PROJECT_PATH="$(pwd)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -p | --project-path) PROJECT_PATH="$2"; shift 2 ;;
    -s | --source) SOURCE_PATH="$2"; shift 2 ;;
    -v | --verbose) VERBOSE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage; print_error "unknown option: $1" ;;
    esac
  done

  local manifest="${PROJECT_PATH}/.walle.config.json"
  read_manifest "$manifest" # stops on missing/v1
  print_info "✓ manifest v2 present (${MF_NAME})"

  # walleVersion must be a semver tag or "local".
  case "$MF_VERSION" in
  local | v[0-9]*.[0-9]*.[0-9]*) print_info "✓ walleVersion pinned: ${MF_VERSION}" ;;
  *) print_error "walleVersion '${MF_VERSION}' is not a semver tag (vX.Y.Z) nor 'local'" ;;
  esac

  # Staleness: if pinned to a semver tag, compare against the latest published release.
  # Skip when "local" (dev/test) or when the remote is unreachable (no network).
  if [ "$MF_VERSION" != "local" ]; then
    local _latest
    _latest="$(resolve_latest_tag 2>/dev/null || echo "")"
    if [ -n "$_latest" ] && [ "$_latest" != "$MF_VERSION" ]; then
      print_warn "version ${MF_VERSION} pinned; latest published is ${_latest} — run: just walle-update"
    elif [ -n "$_latest" ]; then
      print_info "✓ version up to date: ${MF_VERSION}"
    fi
  fi

  # Validate the manifest against the published schema. Needs ajv from the consumer's
  # node_modules — skip with a hint (not a hard error) when dependencies aren't installed,
  # so a missing dep is never misreported as an invalid manifest.
  if [ -d "${PROJECT_PATH}/node_modules/ajv" ]; then
    node -e "
      const Ajv=require('${PROJECT_PATH}/node_modules/ajv').default||require('${PROJECT_PATH}/node_modules/ajv');
      const af=require('${PROJECT_PATH}/node_modules/ajv-formats').default||require('${PROJECT_PATH}/node_modules/ajv-formats');
      const ajv=new Ajv({strict:false}); af(ajv);
      const v=ajv.compile(require('${PROJECT_PATH}/schemas/walle.config.schema.json'));
      if(!v(require('${manifest}'))){console.error(JSON.stringify(v.errors));process.exit(1);}
    " 2>/dev/null || print_error "manifest failed schema validation"
    print_info "✓ manifest valid against schema"
  else
    print_warn "skipping schema validation — dependencies not installed (run: yarn install)"
  fi

  # Validate consumer configs. validate-configs.mjs also needs ajv; same skip-with-hint rule.
  if [ -f "${PROJECT_PATH}/scripts/@walle/validate-configs.mjs" ]; then
    if [ -d "${PROJECT_PATH}/node_modules/ajv" ]; then
      (cd "$PROJECT_PATH" && node ./scripts/@walle/validate-configs.mjs) >/dev/null 2>&1 ||
        print_error "consumer configs failed validation (run: just validate-configs)"
      print_info "✓ consumer configs valid"
    else
      print_warn "skipping config validation — dependencies not installed (run: yarn install)"
    fi
  fi

  # SEED files are consumer-owned: report presence as info only, never fail.
  local _m _rel
  for _m in $MF_MODULES; do
    for _rel in $(module_seed_paths "$_m"); do
      if [ -e "${PROJECT_PATH}/${_rel}" ]; then
        print_info "· seed present (${_m}): ${_rel}"
      else
        print_info "· seed absent (${_m}, consumer-owned): ${_rel}"
      fi
    done
  done

  # Backend API routes need SSR — warn if the module is active but SSR is off.
  case " $MF_MODULES " in
  *" backend "*)
    if ! ssr_enabled "$PROJECT_PATH"; then
      print_warn "· backend active but SSR off — enable 'astro.ssr' in src/configs/app.json for API routes"
    fi
    ;;
  esac

  # Diff managed paths against --source (optional).
  if [ -n "$SOURCE_PATH" ]; then
    print_info "--- managed path diff (source: ${SOURCE_PATH}) ---"
    local _drift=0
    for _m in $MF_MODULES; do
      for _rel in $(module_managed_paths "$_m"); do
        local _src="${SOURCE_PATH}/${_rel}" _dst="${PROJECT_PATH}/${_rel}"
        # Skip the AGENTS.md marker entry — it is not a plain file copy.
        [ "$_rel" = "AGENTS.md" ] && continue
        if [ ! -e "$_src" ]; then
          print_info "  · missing in source: ${_rel}"
          continue
        fi
        if [ ! -e "$_dst" ]; then
          printf '  \033[33m!\033[0m out-of-sync (not in consumer): %s\n' "$_rel"
          _drift=$((_drift + 1))
          continue
        fi
        if [ -d "$_src" ]; then
          local _changed
          _changed=$(diff -rq "$_src" "$_dst" 2>/dev/null | grep -c "^") || true
          if [ "$_changed" -gt 0 ]; then
            printf '  \033[33m!\033[0m out-of-sync (%d file(s)): %s\n' "$_changed" "${_rel}/"
            diff -rq "$_src" "$_dst" 2>/dev/null | sed 's/^/      /' || true
            _drift=$((_drift + _changed))
          else
            print_info "  ✓ in-sync: ${_rel}/"
          fi
        else
          if ! diff -q "$_src" "$_dst" >/dev/null 2>&1; then
            printf '  \033[33m!\033[0m out-of-sync: %s\n' "$_rel"
            _drift=$((_drift + 1))
          else
            print_info "  ✓ in-sync: ${_rel}"
          fi
        fi
      done
    done
    if [ "$_drift" -eq 0 ]; then
      print_info "all managed paths in sync with source."
    else
      print_warn "${_drift} managed path(s) out of sync — run: cli.sh update --source ${SOURCE_PATH}"
    fi
  fi

  print_info "check passed."
  if [ "$VERBOSE" = "1" ]; then print_module_catalog; fi
}

main() {
  local command="" args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
    init | update | add | check) command="$1"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) args+=("$1"); shift ;;
    esac
  done

  [ -n "$command" ] || { usage; print_error "no command given (init|update|add|check)"; }

  "${command}" "${args[@]}"

  if [ -n "${TEMP_DIR:-}" ] && [ -d "${TEMP_DIR}" ]; then
    rm -rf "${TEMP_DIR}"
  fi
}

main "$@"
