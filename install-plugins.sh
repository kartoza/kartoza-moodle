#!/usr/bin/env bash
# install-plugins.sh <zip-dir> <moodle-root>
# Unpacks every plugin zip into <moodle-root>/public/<type-path>/<name>.
# Fails the build (instead of silently skipping) if anything looks wrong.
set -euo pipefail

ZIPDIR="${1:?usage: install-plugins.sh <zip-dir> <moodle-root>}"
ROOT="${2:?usage: install-plugins.sh <zip-dir> <moodle-root>}"
PUB="$ROOT/public"

shopt -s nullglob
zips=("$ZIPDIR"/*.zip)
if [ ${#zips[@]} -eq 0 ]; then
  echo "[plugins] no zip files in $ZIPDIR - nothing to install"
  exit 0
fi

# Plugin type -> folder under public/ (Moodle 5.1+ layout)
declare -A TYPE_PATH=(
  [mod]=mod [block]=blocks [local]=local [tool]=admin/tool [theme]=theme
  [format]=course/format [enrol]=enrol [availability]=availability/condition
  [filter]=filter [auth]=auth [report]=report [repository]=repository
  [qtype]=question/type [qbehaviour]=question/behaviour [plagiarism]=plagiarism
  [booktool]=mod/book/tool [quizaccess]=mod/quiz/accessrule
  [assignsubmission]=mod/assign/submission [assignfeedback]=mod/assign/feedback
  [gradeexport]=grade/export [gradeimport]=grade/import [gradereport]=grade/report
)

core_version=$(sed -nE 's/^\$version[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$PUB/version.php" | head -n1)
echo "[plugins] Moodle core version: ${core_version:-unknown}"

for zip in "${zips[@]}"; do
  tmp=$(mktemp -d)
  unzip -q "$zip" -d "$tmp"
  rm -rf "$tmp/__MACOSX"

  # version.php sits in the zip's single top-level folder (or at the zip root)
  vfile=$(find "$tmp" -mindepth 2 -maxdepth 2 -name version.php | sort | head -n1)
  [ -n "$vfile" ] || vfile=$(find "$tmp" -mindepth 1 -maxdepth 1 -name version.php | head -n1)
  [ -n "$vfile" ] || { echo "[plugins] ERROR: $(basename "$zip"): no version.php at the top level of the plugin" >&2; exit 1; }
  src=$(dirname "$vfile")

  component=$(sed -nE 's/^[^#]*plugin->component[^a-z0-9_]+([a-z0-9_]+).*/\1/p' "$vfile" | head -n1)
  if ! [[ "$component" =~ ^([a-z0-9]+)_(.+)$ ]]; then
    echo "[plugins] ERROR: $(basename "$zip"): cannot read \$plugin->component from version.php" >&2; exit 1
  fi
  ptype="${BASH_REMATCH[1]}"; pname="${BASH_REMATCH[2]}"
  rel="${TYPE_PATH[$ptype]:-}"
  [ -n "$rel" ] || { echo "[plugins] ERROR: $component: plugin type '$ptype' not supported by this script" >&2; exit 1; }

  requires=$(sed -nE 's/^[^#]*plugin->requires[^0-9]+([0-9]+).*/\1/p' "$vfile" | head -n1)
  if [ -n "$requires" ] && [ -n "$core_version" ] && [ "$requires" -gt "$core_version" ]; then
    echo "[plugins] ERROR: $component requires Moodle $requires, but core is $core_version" >&2; exit 1
  fi

  target="$PUB/$rel/$pname"
  rm -rf "$target"
  mkdir -p "$(dirname "$target")"
  cp -a "$src" "$target"
  id www-data >/dev/null 2>&1 && chown -R www-data:www-data "$target"
  echo "[plugins] installed $component -> ${target#$ROOT/}"
  rm -rf "$tmp"
done