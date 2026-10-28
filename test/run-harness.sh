#!/bin/bash
# Quickshell refuses to import QML from outside the folder it was started on,
# so the harness runs from a scratch copy holding the service next to it,
# with a fake shell.json the service reads its settings from.
set -euo pipefail

plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cp -r "$plugin_dir/Service.qml" "$plugin_dir/Model.js" "$plugin_dir/bin" "$plugin_dir/test/harness/shell.qml" "$work/"
cat >"$work/shell.json" <<'JSON'
{"version": 1, "bar": {"layout": {"right": [
  {"id": "paulbob.super-battery", "warningLevel": 33, "futureField": "kept"}
]}}}
JSON
# Stands in for omarchy-file-select: "picks" the freedesktop bell.
cat >"$work/fake-file-select" <<'SH'
#!/bin/bash
echo /usr/share/sounds/freedesktop/stereo/bell.oga
SH
chmod +x "$work/fake-file-select"
export SUPER_BATTERY_FILE_SELECT="$work/fake-file-select"

timeout 25 quickshell -p "$work" 2>&1 | grep -E 'PASS|FAIL|ERROR|Warning:'
