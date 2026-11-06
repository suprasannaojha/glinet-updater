#!/bin/sh
set -u

TESTS_DIR=$(cd "$(dirname "$0")" && pwd -P)
REPO_ROOT=$(dirname "$TESTS_DIR")
failures=0

for test_script in "$TESTS_DIR"/test_*.sh; do
  printf '== %s\n' "$(basename "$test_script")"
  sh "$test_script" "$REPO_ROOT" || failures=$((failures + 1))
done

printf '== %s\n' test_distsign.py
python3 -I "$TESTS_DIR/test_distsign.py" "$REPO_ROOT" || failures=$((failures + 1))

if [ "$failures" -eq 0 ]; then
  echo "all tests passed"
else
  echo "$failures test file(s) failed"
  exit 1
fi
