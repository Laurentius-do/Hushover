#!/bin/bash
# Builds Hushover, installs it to /Applications and (re)starts it.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

# Quit the running instance and wait until it is really gone – otherwise `open` below would just
# re-activate the old process. Hushover quits cleanly on SIGTERM; a hung one gets killed after 5 s.
if pgrep -x Hushover >/dev/null; then
    pkill -x Hushover || true
    for _ in {1..50}; do
        pgrep -x Hushover >/dev/null || break
        sleep 0.1
    done
    if pgrep -x Hushover >/dev/null; then
        echo "Hushover is not responding – killing it."
        pkill -KILL -x Hushover || true
        sleep 0.5
    fi
fi
rm -rf /Applications/Hushover.app
ditto build/Hushover.app /Applications/Hushover.app
open /Applications/Hushover.app

echo "Installed: /Applications/Hushover.app"
