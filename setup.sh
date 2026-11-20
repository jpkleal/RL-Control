#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/manifest.conf"
source "$SCRIPT_DIR/lib/common.sh"

cd "$SCRIPT_DIR"

: "${EXPERIMENT_TAG:=}"
: "${PYTHON_VERSION:?PYTHON_VERSION is not set in manifest.conf}"
: "${POETRY_VERSION:?POETRY_VERSION is not set in manifest.conf}"

PYTHON_BIN="python${PYTHON_VERSION}"
VERSIONS_FILE="$SCRIPT_DIR/shared/results/versions.json"

die() { err "$*"; exit 1; }

# "Poetry (version 2.2.1)" -> "2.2" ; "Python 3.12.7" -> "3.12"
major_minor() { sed -nE 's/[^0-9]*([0-9]+)\.([0-9]+).*/\1.\2/p' <<< "$1" | head -n1; }

# Tag a repo should be on: its own tag, else EXPERIMENT_TAG, else "" (branch tip).
effective_tag() { if [ -n "$1" ]; then echo "$1"; else echo "$EXPERIMENT_TAG"; fi; }

# Reads one REPOS entry into: name url branch tag folder
parse_repo() {
  local extra
  IFS='|' read -r name url branch tag folder extra <<< "$1"
  if [ -z "${folder:-}" ] || [ -n "${extra:-}" ]; then
    die "Invalid REPOS entry '$1' - expected \"name|git_url|branch|tag|local_folder\" (tag may be empty)."
  fi
}

# Fetches the configured branch (explicit refspec, so it also works on old
# --single-branch clones) and all tags. Never touches the working tree.
fetch_repo() {
  local folder="$1" branch="$2"
  git -C "$folder" fetch --quiet --tags origin \
    "+refs/heads/${branch}:refs/remotes/origin/${branch}" \
    || die "[$folder] git fetch failed (network, auth, missing branch '$branch', or a local tag that differs from the remote one)."
}

# Uncommitted changes in a repo, ignoring the symlinks this script creates
# inside it (some repos do not gitignore them).
repo_status() {
  local folder="$1" entry project_path shared_name
  local -a excludes=()
  for entry in "${SYMLINKS[@]}"; do
    IFS='|' read -r project_path shared_name <<< "$entry"
    case "$project_path" in
      "$folder"/*) excludes+=(":(exclude)${project_path#"$folder"/}") ;;
    esac
  done
  git -C "$folder" status --porcelain --untracked-files=all -- . ${excludes[@]+"${excludes[@]}"}
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

json_str() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }
json_str_or_null() { if [ -n "$1" ]; then json_str "$1"; else printf 'null'; fi; }

# ---------------------------------------------------------------------------
log "==> Checking tool versions (Python $PYTHON_VERSION, Poetry $POETRY_VERSION)"
# ---------------------------------------------------------------------------
command -v poetry >/dev/null 2>&1 || die "poetry not found on PATH (required: $POETRY_VERSION.x)."
POETRY_FULL="$(poetry --version 2>/dev/null)"
[ "$(major_minor "$POETRY_FULL")" = "$POETRY_VERSION" ] \
  || die "Poetry $POETRY_VERSION.x required, found: $POETRY_FULL"

command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "$PYTHON_BIN not found on PATH (required by manifest.conf)."
[ "$(major_minor "$("$PYTHON_BIN" --version 2>&1)")" = "$PYTHON_VERSION" ] \
  || die "$PYTHON_BIN reports $("$PYTHON_BIN" --version 2>&1), expected $PYTHON_VERSION.x"
log "  [ok] $POETRY_FULL, $("$PYTHON_BIN" --version 2>&1)"

# ---------------------------------------------------------------------------
log "==> Checking repositories (nothing is modified in this step)"
# ---------------------------------------------------------------------------
for entry in "${REPOS[@]}"; do
  parse_repo "$entry"
  want_tag="$(effective_tag "$tag")"

  if [ -d "$folder/.git" ]; then
    changes="$(repo_status "$folder")"
    [ -z "$changes" ] \
      || die "[$name] has uncommitted changes - commit or stash them, then re-run:"$'\n'"$changes"

    fetch_repo "$folder" "$branch"

    if [ -n "$want_tag" ]; then
      git -C "$folder" rev-parse -q --verify "refs/tags/${want_tag}^{commit}" >/dev/null \
        || die "[$name] tag '$want_tag' does not exist on the remote."
    fi

    # Local commits that are not on any remote branch would be lost from view
    # by a checkout - refuse (unless HEAD already is the wanted tag).
    head_sha="$(git -C "$folder" rev-parse HEAD)"
    tag_sha=""
    [ -n "$want_tag" ] && tag_sha="$(git -C "$folder" rev-parse "refs/tags/${want_tag}^{commit}")"
    if [ "$head_sha" != "$tag_sha" ] && [ -z "$(git -C "$folder" branch -r --contains HEAD)" ]; then
      die "[$name] HEAD ($head_sha) has commits that are not on the remote - push them first."
    fi

    # The configured local branch must not be ahead of / diverged from the remote.
    if git -C "$folder" rev-parse -q --verify "refs/heads/$branch" >/dev/null \
       && ! git -C "$folder" merge-base --is-ancestor "refs/heads/$branch" "refs/remotes/origin/$branch"; then
      die "[$name] local branch '$branch' has commits that are not on origin/$branch - push or reset it first."
    fi
  else
    git ls-remote --exit-code --heads "$url" "$branch" >/dev/null 2>&1 \
      || die "[$name] branch '$branch' not found at $url (or no access)."
    if [ -n "$want_tag" ]; then
      git ls-remote --exit-code --tags "$url" "refs/tags/$want_tag" >/dev/null 2>&1 \
        || die "[$name] tag '$want_tag' does not exist at $url."
    fi
  fi
  log "  [ok] $name"
done

# ---------------------------------------------------------------------------
log "==> Cloning / updating repositories"
# ---------------------------------------------------------------------------
for entry in "${REPOS[@]}"; do
  parse_repo "$entry"
  want_tag="$(effective_tag "$tag")"

  if [ ! -d "$folder/.git" ]; then
    log "  [$name] cloning ($branch)"
    git clone --quiet --branch "$branch" "$url" "$folder"
    fetch_repo "$folder" "$branch"
  fi

  if [ -n "$want_tag" ]; then
    git -C "$folder" checkout --quiet --detach "refs/tags/$want_tag"
    if ! git -C "$folder" merge-base --is-ancestor HEAD "refs/remotes/origin/$branch"; then
      log "  [warn] [$name] tag '$want_tag' is not on branch '$branch'"
    fi
    log "  [$name] at tag '$want_tag' ($(git -C "$folder" rev-parse --short HEAD))"
  else
    git -C "$folder" checkout --quiet "$branch"
    git -C "$folder" pull --quiet --ff-only origin "$branch" \
      || die "[$name] could not fast-forward '$branch' to origin/$branch."
    log "  [$name] at tip of '$branch' ($(git -C "$folder" rev-parse --short HEAD)) - not pinned"
  fi
done

# ---------------------------------------------------------------------------
log "==> Installing dependencies (poetry install, Python $PYTHON_VERSION)"
# ---------------------------------------------------------------------------
for entry in "${REPOS[@]}"; do
  parse_repo "$entry"
  log "  [$name] poetry install"
  (
    cd "$SCRIPT_DIR/$folder"
    poetry env use --quiet "$PYTHON_BIN"
    poetry install
  )
  env_py="$(cd "$SCRIPT_DIR/$folder" && poetry run python -c 'import platform; print(platform.python_version())')"
  [ "$(major_minor "$env_py")" = "$PYTHON_VERSION" ] \
    || die "[$name] Poetry environment uses Python $env_py, expected $PYTHON_VERSION.x"
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

# ---------------------------------------------------------------------------
log "==> Writing shared/results/versions.json"
# ---------------------------------------------------------------------------
# Describes the environment configured by this setup run (not a training run).
# Written to a temp file and moved into place, so a failed setup never
# leaves a partial or stale-but-rewritten file behind.
pinned=true
repos_json=""
for entry in "${REPOS[@]}"; do
  parse_repo "$entry"
  want_tag="$(effective_tag "$tag")"
  [ -z "$want_tag" ] && pinned=false

  sha="$(git -C "$folder" rev-parse HEAD)"
  resolved="$(git -C "$folder" describe --tags --exact-match HEAD 2>/dev/null || true)"
  dirty=false
  [ -n "$(repo_status "$folder")" ] && dirty=true
  env_py="$(cd "$SCRIPT_DIR/$folder" && poetry run python -c 'import platform; print(platform.python_version())')"

  [ -n "$repos_json" ] && repos_json+=","
  repos_json+="
    {
      \"name\": $(json_str "$name"),
      \"branch\": $(json_str "$branch"),
      \"tag\": $(json_str_or_null "$want_tag"),
      \"resolved_tag\": $(json_str_or_null "$resolved"),
      \"sha\": $(json_str "$sha"),
      \"dirty\": $dirty,
      \"python\": $(json_str "$env_py")
    }"
done

configs_json=""
for cfg in "$SCRIPT_DIR"/configs/*.toml; do
  [ -e "$cfg" ] || continue
  [ -n "$configs_json" ] && configs_json+=","
  configs_json+="
      $(json_str "configs/$(basename "$cfg")"): $(json_str "$(sha256_of "$cfg")")"
done

ctl_sha=""
ctl_dirty=false
if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  ctl_sha="$(git -C "$SCRIPT_DIR" rev-parse HEAD)"
  [ -n "$(git -C "$SCRIPT_DIR" status --porcelain)" ] && ctl_dirty=true
fi
poetry_version="$(sed -nE 's/.*version ([0-9][0-9.]*).*/\1/p' <<< "$POETRY_FULL")"

tmp_file="$(mktemp "$SCRIPT_DIR/shared/results/.versions.json.XXXXXX")"
cat > "$tmp_file" <<EOF
{
  "pinned": $pinned,
  "experiment_tag": $(json_str_or_null "$EXPERIMENT_TAG"),
  "repos": [$repos_json
  ],
  "rl_control": {
    "sha": $(json_str_or_null "$ctl_sha"),
    "dirty": $ctl_dirty,
    "manifest_sha256": $(json_str "$(sha256_of "$SCRIPT_DIR/manifest.conf")"),
    "configs_sha256": {$configs_json
    }
  },
  "poetry": $(json_str "$poetry_version")
}
EOF
mv "$tmp_file" "$VERSIONS_FILE"

if [ "$pinned" = true ]; then
  log "  [ok] all repos pinned to tags"
else
  log "  [warn] not all repos are pinned to a tag - this environment is NOT reproducible"
fi
[ "$ctl_dirty" = true ] && log "  [warn] RL-Control has uncommitted changes (configs may differ from its HEAD)"

log "==> Setup complete"
