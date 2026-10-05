#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$ROOT/.." && pwd)"
TOP="${TOP:-$WORKSPACE_ROOT/fox_14.1-replay}"
LOCK_DIR="${LOCK_DIR:-$ROOT/.ci-staging/source-lock/fox_14.1}"
MANIFEST_ROOT="$WORKSPACE_ROOT/.source-tools/fox-14.1-lock-manifest"
SOURCE_STAMP="$TOP/.ofox-dash-source-lock"

case "$TOP" in
  "$WORKSPACE_ROOT"/*) ;;
  *) echo "Refusing TOP outside workspace: $TOP" >&2; exit 2 ;;
esac

for cmd in git repo python3 sha256sum awk sort cmp cut sed; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing required host command: $cmd" >&2
    exit 3
  }
done

verify_lock_files() {
  [[ -f "$LOCK_DIR/default.xml" &&
     -f "$LOCK_DIR/metadata.txt" &&
     -f "$LOCK_DIR/patches.index" &&
     -f "$LOCK_DIR/SHA256SUMS" ]] || {
    echo "Incomplete canonical source lock: $LOCK_DIR" >&2
    exit 4
  }

  (cd "$LOCK_DIR" && sha256sum -c SHA256SUMS)

  python3 - "$LOCK_DIR/metadata.txt" "$LOCK_DIR/patches.index" <<'PY'
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

rows = [line for line in patches.splitlines() if line]
if len(rows) != 3:
    raise SystemExit(f"patches.index row count is {len(rows)}, expected 3")
if any(line.count("\t") != 1 for line in rows):
    raise SystemExit("patches.index is not tab-delimited")
PY
}

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

clone_special_projects() {
  while IFS=$'\t' read -r kind path url revision; do
    [[ "$kind" == "SPECIAL" ]] || continue
    [[ ! -e "$TOP/$path" ]] || {
      echo "Special project unexpectedly exists after repo sync: $path" >&2
      exit 5
    }

    mkdir -p "$(dirname "$TOP/$path")"
    git clone --no-checkout "$url" "$TOP/$path"
    git -C "$TOP/$path" checkout --detach "$revision"
  done < "$LOCK_DIR/metadata.txt"
}

apply_locked_patches() {
  while IFS=$'\t' read -r path patch_rel; do
    [[ -n "$path" && -n "$patch_rel" ]] || continue
    git -C "$TOP/$path" apply --binary --check "$LOCK_DIR/$patch_rel"
    git -C "$TOP/$path" apply --binary "$LOCK_DIR/$patch_rel"
  done < "$LOCK_DIR/patches.index"
}

verify_source_against_lock() {
  local expected_heads="$TOP/.ofox-dash-expected-heads"

  python3 - "$LOCK_DIR/default.xml" > "$expected_heads" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
projects = root.findall("project")

if len(projects) != 659:
    raise SystemExit(f"unexpected project count: {len(projects)}")

seen = set()
for p in projects:
    path = p.get("path") or p.get("name")
    rev = p.get("revision")
    if not path or not rev or len(rev) != 40:
        raise SystemExit(f"invalid project lock: {path!r} {rev!r}")
    if path in seen:
        raise SystemExit(f"duplicate project path: {path}")
    seen.add(path)
    print(f"{path}\t{rev}")

if "bootable/recovery" in seen or "vendor/recovery" in seen:
    raise SystemExit("special OrangeFox projects must not be in default.xml")
PY

  while IFS=$'\t' read -r path revision; do
    [[ -e "$TOP/$path" ]] || {
      echo "Locked project is missing: $path" >&2
      exit 6
    }
    actual="$(git -C "$TOP/$path" rev-parse HEAD)"
    [[ "$actual" == "$revision" ]] || {
      echo "Locked project HEAD mismatch: $path" >&2
      echo "expected=$revision actual=$actual" >&2
      exit 6
    }
  done < "$expected_heads"
  rm -f "$expected_heads"

  while IFS=$'\t' read -r kind path url revision; do
    [[ "$kind" == "SPECIAL" ]] || continue
    [[ -e "$TOP/$path" ]] || {
      echo "Special project missing: $path" >&2
      exit 7
    }
    actual="$(git -C "$TOP/$path" rev-parse HEAD)"
    [[ "$actual" == "$revision" ]] || {
      echo "Special project HEAD mismatch: $path" >&2
      echo "expected=$revision actual=$actual" >&2
      exit 7
    }
  done < "$LOCK_DIR/metadata.txt"

  local actual_dirty="$TOP/.ofox-dash-dirty.actual"
  local expected_dirty="$TOP/.ofox-dash-dirty.expected"

  list_actual_dirty_projects "$actual_dirty"
  cut -f1 "$LOCK_DIR/patches.index" | sed '/^$/d' | sort -u > "$expected_dirty"

  if ! cmp -s "$actual_dirty" "$expected_dirty"; then
    echo "Dirty-project set differs from canonical lock." >&2
    echo "--- expected ---" >&2
    cat "$expected_dirty" >&2
    echo "--- actual ---" >&2
    cat "$actual_dirty" >&2
    exit 8
  fi

  rm -f "$actual_dirty" "$expected_dirty"

  while IFS=$'\t' read -r path patch_rel; do
    [[ -n "$path" && -n "$patch_rel" ]] || continue

    if git -C "$TOP/$path" status --porcelain=v1 | grep -q '^?? '; then
      echo "Untracked files are not allowed in locked project: $path" >&2
      exit 9
    fi

    project="$TOP/$path"
    expected_index="$TOP/.ofox-dash-expected-index.$"
    actual_index="$TOP/.ofox-dash-actual-index.$"
    rm -f "$expected_index" "$actual_index"

    GIT_INDEX_FILE="$expected_index" git -C "$project" read-tree HEAD
    GIT_INDEX_FILE="$expected_index" git -C "$project" apply --cached --binary "$LOCK_DIR/$patch_rel"
    expected_tree="$(GIT_INDEX_FILE="$expected_index" git -C "$project" write-tree)"

    GIT_INDEX_FILE="$actual_index" git -C "$project" read-tree HEAD
    GIT_INDEX_FILE="$actual_index" git -C "$project" add -A -- .
    actual_tree="$(GIT_INDEX_FILE="$actual_index" git -C "$project" write-tree)"

    rm -f "$expected_index" "$actual_index"

    if [[ "$actual_tree" != "$expected_tree" ]]; then
      echo "Working-tree content mismatch: $path" >&2
      echo "expected_tree=$expected_tree actual_tree=$actual_tree" >&2
      exit 9
    fi
  done < "$LOCK_DIR/patches.index"
}

verify_lock_files

[[ ! -e "$TOP/.repo" ]] || {
  echo "Replay requires a fresh target; .repo already exists at $TOP" >&2
  exit 10
}

rm -rf "$MANIFEST_ROOT" "$TOP"
mkdir -p "$MANIFEST_ROOT" "$TOP"

cp "$LOCK_DIR/default.xml" "$MANIFEST_ROOT/default.xml"
git -C "$MANIFEST_ROOT" init -q -b main
git -C "$MANIFEST_ROOT" add default.xml
git -C "$MANIFEST_ROOT" \
  -c user.name='OFOX DASH Source Lock' \
  -c user.email='noreply@localhost' \
  commit -q -m 'fox_14.1 resolved source lock'

(
  cd "$TOP"
  repo init -u "file://$MANIFEST_ROOT" -b main -m default.xml
  repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune --force-sync
)

clone_special_projects
apply_locked_patches
verify_source_against_lock

lock_id="$(sha256sum "$LOCK_DIR/SHA256SUMS" | awk '{print $1}')"
printf '%s\n' "$lock_id" > "$SOURCE_STAMP"

echo "[dash14] exact canonical fox_14.1 replay verified"
echo "[dash14] lock_id=$lock_id"
