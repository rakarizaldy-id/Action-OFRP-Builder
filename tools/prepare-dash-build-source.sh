#!/usr/bin/env bash
set -euo pipefail

BUILDER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOP="${TOP:-$BUILDER_ROOT/fox_14.1}"
CONTROLLER_ROOT="${CONTROLLER_ROOT:-$BUILDER_ROOT/.dash-controller}"
LOCK_DIR="${LOCK_DIR:-$CONTROLLER_ROOT/PROJECT_NOTES/SOURCE_LOCK/fox_14.1}"
SYNC_DIR="$BUILDER_ROOT/.source-tools/orangefox-sync"

for cmd in git python3 sha256sum awk sort cmp cut; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 2; }
done

for rel in SHA256SUMS default.xml metadata.txt patches.index; do
  [[ -f "$LOCK_DIR/$rel" ]] || { echo "Missing canonical lock file: $LOCK_DIR/$rel" >&2; exit 3; }
done
(
  cd "$LOCK_DIR"
  sha256sum -c SHA256SUMS
)

[[ ! -e "$TOP" ]] || {
  echo "Refusing non-fresh source root: $TOP" >&2
  exit 4
}

official_sync_url="$(awk -F '\t' '$1=="OFFICIAL_SYNC_URL"{print $2; exit}' "$LOCK_DIR/metadata.txt")"
official_sync_commit="$(awk -F '\t' '$1=="OFFICIAL_SYNC_COMMIT"{print $2; exit}' "$LOCK_DIR/metadata.txt")"
official_branch="$(awk -F '\t' '$1=="OFFICIAL_BRANCH"{print $2; exit}' "$LOCK_DIR/metadata.txt")"

[[ "$official_sync_url" == https://gitlab.com/OrangeFox/sync.git ]] || {
  echo "Unexpected OrangeFox sync URL: $official_sync_url" >&2; exit 5;
}
[[ "$official_sync_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "Invalid pinned OrangeFox sync commit." >&2; exit 5;
}
[[ "$official_branch" == 14.1 ]] || {
  echo "Unexpected OrangeFox branch: $official_branch" >&2; exit 5;
}

mkdir -p "$(dirname "$SYNC_DIR")"
rm -rf "$SYNC_DIR"
git clone "$official_sync_url" "$SYNC_DIR"
git -C "$SYNC_DIR" checkout --detach "$official_sync_commit"

echo "[dash14] official sync commit=$official_sync_commit"
(
  cd "$SYNC_DIR"
  ./orangefox_sync.sh --branch "$official_branch" --path "$TOP"
)

[[ -d "$TOP/.repo" ]] || { echo "Official sync did not create repo tree." >&2; exit 6; }

projects="$TOP/.ofox-dash-locked-projects.tsv"
python3 - "$LOCK_DIR/default.xml" > "$projects" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
rows = []
seen = set()
for p in root.findall("project"):
    path = p.get("path") or p.get("name")
    rev = p.get("revision")
    if not path or not rev or len(rev) != 40:
        raise SystemExit(f"invalid project lock: {path!r} {rev!r}")
    if path in seen:
        raise SystemExit(f"duplicate project path: {path}")
    seen.add(path)
    rows.append((path, rev))
if len(rows) != 659:
    raise SystemExit(f"expected 659 locked projects, got {len(rows)}")
for path, rev in rows:
    print(f"{path}\t{rev}")
PY

while IFS=$'\t' read -r path rev; do
  [[ -d "$TOP/$path/.git" || -f "$TOP/$path/.git" ]] || {
    echo "Missing locked project checkout: $path" >&2; exit 7;
  }
  got="$(git -C "$TOP/$path" rev-parse HEAD)"
  [[ "$got" == "$rev" ]] || {
    echo "Locked HEAD mismatch: $path" >&2
    echo "expected=$rev got=$got" >&2
    exit 7
  }
done < "$projects"

while IFS=$'\t' read -r tag path remote rev; do
  [[ "$tag" == SPECIAL ]] || continue
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid special revision: $path" >&2; exit 7; }
  got="$(git -C "$TOP/$path" rev-parse HEAD)"
  [[ "$got" == "$rev" ]] || {
    echo "Special HEAD mismatch: $path" >&2
    echo "expected=$rev got=$got" >&2
    exit 7
  }
done < "$LOCK_DIR/metadata.txt"

actual_dirty="$TOP/.ofox-dash-dirty.actual"
expected_dirty="$TOP/.ofox-dash-dirty.expected"
: > "$actual_dirty"
while IFS=$'\t' read -r path rev; do
  [[ -n "$(git -C "$TOP/$path" status --porcelain=v1)" ]] && printf '%s\n' "$path" >> "$actual_dirty"
done < "$projects"
while IFS=$'\t' read -r tag path remote rev; do
  [[ "$tag" == SPECIAL ]] || continue
  [[ -n "$(git -C "$TOP/$path" status --porcelain=v1)" ]] && printf '%s\n' "$path" >> "$actual_dirty"
done < "$LOCK_DIR/metadata.txt"
sort -u -o "$actual_dirty" "$actual_dirty"
cut -f1 "$LOCK_DIR/patches.index" | sort -u > "$expected_dirty"

if ! cmp -s "$actual_dirty" "$expected_dirty"; then
  echo "Canonical dirty-project set mismatch." >&2
  echo "--- expected ---" >&2; cat "$expected_dirty" >&2
  echo "--- actual ---" >&2; cat "$actual_dirty" >&2
  exit 8
fi

while IFS=$'\t' read -r path patch_rel; do
  [[ -n "$path" && -n "$patch_rel" ]] || continue
  project="$TOP/$path"

  if git -C "$project" status --porcelain=v1 | grep -q '^?? '; then
    echo "Untracked files are not allowed in canonical dirty project: $path" >&2
    exit 9
  fi

  expected_index="$TOP/.ofox-expected-index.$$"
  actual_index="$TOP/.ofox-actual-index.$$"
  rm -f "$expected_index" "$actual_index"

  GIT_INDEX_FILE="$expected_index" git -C "$project" read-tree HEAD
  GIT_INDEX_FILE="$expected_index" git -C "$project" apply --cached --binary "$LOCK_DIR/$patch_rel"
  expected_tree="$(GIT_INDEX_FILE="$expected_index" git -C "$project" write-tree)"

  GIT_INDEX_FILE="$actual_index" git -C "$project" read-tree HEAD
  GIT_INDEX_FILE="$actual_index" git -C "$project" add -A -- .
  actual_tree="$(GIT_INDEX_FILE="$actual_index" git -C "$project" write-tree)"

  rm -f "$expected_index" "$actual_index"

  [[ "$actual_tree" == "$expected_tree" ]] || {
    echo "Canonical patched content mismatch: $path" >&2
    echo "expected_tree=$expected_tree actual_tree=$actual_tree" >&2
    exit 9
  }
done < "$LOCK_DIR/patches.index"

source_lock_id="$(sha256sum "$LOCK_DIR/SHA256SUMS" | awk '{print $1}')"
printf '%s\n' "$source_lock_id" > "$TOP/.ofox-dash-source-lock"

echo "[dash14] canonical source verified"
echo "[dash14] source_lock=$source_lock_id"
df -h /
