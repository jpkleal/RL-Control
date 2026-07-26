#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/manifest.conf"
source "$SCRIPT_DIR/lib/common.sh"

cd "$SCRIPT_DIR"

log "==> Cloning / updating repositories"
for entry in "${REPOS[@]}"; do
  IFS='|' read -r name url branch folder <<< "$entry"
  if [ -d "$folder/.git" ]; then
    log "  [$name] already cloned, updating to latest '$branch'"
    git -C "$folder" fetch origin "$branch"
    git -C "$folder" checkout "$branch"
    git -C "$folder" pull origin "$branch"
  else
    log "  [$name] cloning ($branch)"
    git clone --branch "$branch" --single-branch "$url" "$folder"
  fi
done

log "==> Installing dependencies (poetry install)"
for entry in "${REPOS[@]}"; do
  IFS='|' read -r name url branch folder <<< "$entry"
  log "  [$name] poetry install"
  ( cd "$SCRIPT_DIR/$folder" && poetry install )
done

log "==> Creating shared directories"
for dir in "${SHARED_DIRS[@]}"; do
  mkdir -p "$SCRIPT_DIR/shared/$dir"
done

log "==> Linking shared directories into projects"
for entry in "${SYMLINKS[@]}"; do
  IFS='|' read -r project_path shared_name <<< "$entry"
  target="$SCRIPT_DIR/shared/$shared_name"
  link_path="$SCRIPT_DIR/$project_path"
  link_parent="$(dirname "$link_path")"
  mkdir -p "$link_parent"

  if [ -L "$link_path" ]; then
    current_target="$(readlink -f "$link_path" || true)"
    if [ "$current_target" = "$(readlink -f "$target")" ]; then
      log "  [ok]   $project_path already linked correctly"
      continue
    else
      log "  [fix]  $project_path points elsewhere, relinking"
      rm "$link_path"
    fi
  elif [ -e "$link_path" ]; then
    backup="${link_path}.bak.$(date +%s)"
    log "  [warn] $project_path exists and is not a symlink, backing it up to $(basename "$backup")"
    mv "$link_path" "$backup"
  fi

  ln -s "$target" "$link_path"
  log "  [link] $project_path -> shared/$shared_name"
done

log "==> Setup complete"
