#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
check_tmp="$(mktemp -d "${TMPDIR:-/tmp}/shungao-check.XXXXXX")"
trap 'rm -rf "$check_tmp"' EXIT
swiftc Sources/document_library.swift tests/library_test/main.swift -o "$check_tmp/library-test" -module-cache-path "$check_tmp/modules"
"$check_tmp/library-test"
swiftc tests/js_cli.swift -o "$check_tmp/js-check" -framework JavaScriptCore -module-cache-path "$check_tmp/modules"
"$check_tmp/js-check" Sources/trajectory.js tests/trajectory_tests.js > "$check_tmp/trajectory.json"
python_for_tests="${PYTHON_FOR_TESTS:-python3}"
"$python_for_tests" -B -s - "$check_tmp/trajectory.json" <<'PYCODE'
import json,sys
report=json.load(open(sys.argv[1]));checks=report['checks'];failed=[c for c in checks if not c['passed']]
print(f"Trajectory checks: {len(checks)-len(failed)}/{len(checks)}")
if failed: print(failed);raise SystemExit(1)
PYCODE
"$python_for_tests" -B -s -m unittest discover -s tests -p 'test_*.py' -v
