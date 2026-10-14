#!/bin/sh
# Builds and runs every full program in the guides, so an API change can't silently break the
# docs. Code blocks titled like files (```zig title="src/main.zig") are written out page by page.
set -eu
cd "$(dirname "$0")"
for page in $(grep -rl 'title="src/main.zig"' ../docs | sort); do
    echo "== $page"
    rm -rf src && mkdir src
    python3 - "$page" <<'PY'
import os, re, sys
text = open(sys.argv[1]).read()
for name, code in re.findall(r'```\w+ title="([^"]+)"\n(.*?)```', text, re.S):
    path = name if name.startswith("src/") else os.path.join("src", name)
    open(path, "w").write(code)
PY
    zig build
done
