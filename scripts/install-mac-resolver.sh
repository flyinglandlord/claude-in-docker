#!/bin/bash
set -euo pipefail
[[ $(uname) == Darwin && $# == 1 ]] || { echo 'usage: install-mac-resolver.sh suffix[,suffix...]'; exit 1; }
label=local.claude-in-docker.mac-resolver
dest="$HOME/Library/Application Support/claude-in-docker"
plist="$HOME/Library/LaunchAgents/$label.plist"
mkdir -p "$dest" "$(dirname "$plist")"
install -m 700 "$(dirname "$0")/mac-resolver.py" "$dest/mac-resolver.py"
/usr/bin/python3 - "$plist" "$label" "$dest/mac-resolver.py" "$1" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump(dict(Label=sys.argv[2], ProgramArguments=['/usr/bin/python3', sys.argv[3], sys.argv[4]],
                       RunAtLoad=True, KeepAlive=True), output)
PY
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
