#!/usr/bin/env bash
set -euo pipefail

CONTROLLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$CONTROLLER_ROOT/.." && pwd)"
TOP="${TOP:-$WORKSPACE_ROOT/fox_14.1}"
SOURCE_LOCK_OUT="${SOURCE_LOCK_OUT:-$CONTROLLER_ROOT/.ci-artifacts/source-lock/fox_14.1}"

OFFICIAL_SYNC_URL="https://gitlab.com/OrangeFox/sync.git"
OFFICIAL_BRANCH="14.1"
SYNC_ROOT="$WORKSPACE_ROOT/.source-tools/orangefox-sync"
PROVISIONAL_STAMP="$TOP/.ofox-dash-source-lock.provisional"

case "$TOP" in
  "$WORKSPACE_ROOT"/*) ;;
  *) echo "Refusing TOP outside workspace: $TOP" >&2; exit 2 ;;
esac

case "$SOURCE_LOCK_OUT" in
  "$WORKSPACE_ROOT"/*) ;;
  *) echo "Refusing source lock output outside workspace: $SOURCE_LOCK_OUT" >&2; exit 2 ;;
esac

for cmd in git repo python3 sha256sum awk sort cmp; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing required host command: $cmd" >&2
    exit 3
  }
done

list_actual_dirty_projects() {
  local out="$1"
  : > "$out"
  (
    cd "$TOP"
    repo forall -c 'if test -n "$(git status --porcelain=v1)"; then printf "%s\n" "$REPO_PATH"; fi'
  ) >> "$out"

  for special in bootable/recovery vendor/recovery; do
    if [[ -d "$TOP/$special/.git" || -f "$TOP/$special/.git" ]]; then
      if [[ -n "$(git -C "$TOP/$special" status --porcelain=v1)" ]]; then
        printf '%s\n' "$special" >> "$out"
      fi
    fi
  done

  sort -u -o "$out" "$out"
}

verify_lock_files() {
  local dir="$1"
  [[ -f "$dir/default.xml" &&
     -f "$dir/metadata.txt" &&
     -f "$dir/patches.index" &&
     -f "$dir/SHA256SUMS" ]] || {
    echo "Incomplete fox_14.1 source lock: $dir" >&2
    return 1
  }

  (cd "$dir" && sha256sum -c SHA256SUMS)

  python3 - "$dir/metadata.txt" "$dir/patches.index" <<'PY'
import sys
from pathlib import Path

metadata = Path(sys.argv[1]).read_text(encoding="utf-8")
patches = Path(sys.argv[2]).read_text(encoding="utf-8")

for label, text in (("metadata.txt", metadata), ("patches.index", patches)):
    if "\\t" in text or "\\n" in text:
        raise SystemExit(f"{label} contains literal escaped TSV/newline sequences")

meta_lines = metadata.splitlines()
if len(meta_lines) != 5:
    raise SystemExit(f"metadata.txt line count is {len(meta_lines)}, expected 5")
if any("\t" not in line for line in meta_lines):
    raise SystemExit("metadata.txt is not tab-delimited")

for line in patches.splitlines():
    if line and line.count("\t") != 1:
        raise SystemExit(f"invalid patches.index row: {line!r}")
PY
}

capture_lock() {
  local dir="$1"

  rm -rf "$dir"
  mkdir -p "$dir/patches"

  local raw="$dir/default.raw.xml"
  (
    cd "$TOP"
    repo manifest -r -o "$raw"
  )

  python3 - "$raw" "$dir/default.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

src, dst = sys.argv[1:3]
tree = ET.parse(src)
root = tree.getroot()
special = {"bootable/recovery", "vendor/recovery"}

for project in list(root.findall("project")):
    path = project.get("path") or project.get("name")
    if path in special:
        root.remove(project)

ET.indent(tree, space="  ")
tree.write(dst, encoding="utf-8", xml_declaration=True)
PY

  rm -f "$raw"

  {
    printf 'OFFICIAL_SYNC_URL\t%s\n' "$OFFICIAL_SYNC_URL"
    printf 'OFFICIAL_SYNC_COMMIT\t%s\n' "$(git -C "$SYNC_ROOT" rev-parse HEAD)"
    printf 'OFFICIAL_BRANCH\t%s\n' "$OFFICIAL_BRANCH"

    for special in bootable/recovery vendor/recovery; do
      [[ -d "$TOP/$special" ]] || {
        echo "Official OrangeFox project missing after sync: $special" >&2
        return 1
      }

      remote="$(git -C "$TOP/$special" remote get-url origin)"
      revision="$(git -C "$TOP/$special" rev-parse HEAD)"
      printf 'SPECIAL\t%s\t%s\t%s\n' "$special" "$remote" "$revision"
    done
  } > "$dir/metadata.txt"

  local dirty="$TOP/.ofox-dash-dirty.capture"
  list_actual_dirty_projects "$dirty"
  : > "$dir/patches.index"

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue

    if git -C "$TOP/$path" status --porcelain=v1 | grep -q '^?? '; then
      echo "Cannot lock project with untracked files: $path" >&2
      rm -f "$dirty"
      return 1
    fi

    patch_rel="patches/$path.patch"
    mkdir -p "$dir/$(dirname "$patch_rel")"
    git -C "$TOP/$path" diff --binary HEAD -- . > "$dir/$patch_rel"

    [[ -s "$dir/$patch_rel" ]] || {
      echo "Dirty project produced an empty patch: $path" >&2
      rm -f "$dirty"
      return 1
    }

    printf '%s\t%s\n' "$path" "$patch_rel" >> "$dir/patches.index"
  done < "$dirty"

  rm -f "$dirty"

  (
    cd "$dir"
    find default.xml metadata.txt patches.index patches -type f -print0 |
      sort -z |
      xargs -0 sha256sum > SHA256SUMS
  )

  verify_lock_files "$dir"

  lock_id="$(sha256sum "$dir/SHA256SUMS" | awk '{print $1}')"
  printf '%s\n' "$lock_id" > "$PROVISIONAL_STAMP"

  echo "[dash14] provisional source lock captured: $dir"
  echo "[dash14] lock_id=$lock_id"
}

[[ ! -e "$TOP/.repo" ]] || {
  echo "Bootstrap requires a fresh target; .repo already exists at $TOP" >&2
  exit 4
}

mkdir -p "$(dirname "$SYNC_ROOT")"
rm -rf "$SYNC_ROOT"

git clone --depth=1 "$OFFICIAL_SYNC_URL" "$SYNC_ROOT"

unset USE_SSH
(
  cd "$SYNC_ROOT"
  ./orangefox_sync.sh --branch "$OFFICIAL_BRANCH" --path "$TOP"
)

[[ -d "$TOP/.repo" ]] || {
  echo "Official OrangeFox sync did not produce a repo tree." >&2
  exit 5
}

capture_lock "$SOURCE_LOCK_OUT"
