#!/bin/sh
set -u

REPO_ROOT=$1
. "$REPO_ROOT/tests/lib_assert.sh"
. "$REPO_ROOT/lib/ui.sh"
. "$REPO_ROOT/lib/util.sh"

assert_eq "$(normalize_version v0.107.80)" "0.107.80" "normalize_version removes the v prefix"
assert_eq "$(normalize_version 1.104.4-t938213198-gd38c96d6a)" "1.104.4" "normalize_version removes the build suffix"
assert_true "1.104.5 is newer than 1.104.4" version_gt 1.104.5 1.104.4
assert_true "1.104.0 is newer than 1.92.5 (numeric compare)" version_gt 1.104.0 1.92.5
assert_true "v0.107.80 is newer than 0.107.73" version_gt v0.107.80 0.107.73
assert_false "1.104.4 is not newer than itself" version_gt 1.104.4 1.104.4
assert_false "0.107.73 is not newer than v0.107.80" version_gt 0.107.73 v0.107.80
assert_true "version_eq ignores prefix and suffix" version_eq v1.104.4 1.104.4-t9

quoted=$(shell_quote "it's a \$test; rm -rf /")
eval "unquoted=$quoted"
assert_eq "$unquoted" "it's a \$test; rm -rf /" "shell_quote survives quotes and shell syntax"

assert_done
