#!/bin/sh
set -u

REPO_ROOT=$1
. "$REPO_ROOT/tests/lib_assert.sh"
. "$REPO_ROOT/lib/ui.sh"
. "$REPO_ROOT/lib/util.sh"
. "$REPO_ROOT/lib/tailscale.sh"

STUB_NETFIX=''
STUB_STATUS=0

remote_agent() {
  printf '%s\n' "$STUB_NETFIX"
  return "$STUB_STATUS"
}

netfix_state() {
  STUB_NETFIX=$(printf 'netfix.needed=%s\nnetfix.live=%s\nnetfix.saved=%s' "$1" "$2" "$3")
}

warnings() {
  { tailscale_warn_port_forward_conflict >/dev/null; } 2>&1
}

contains() {
  case $1 in
    *"$2"*) return 0 ;;
  esac
  return 1
}

netfix_state yes no no
output=$(warnings)
assert_true "warns when the rule is needed and missing" contains "$output" "glu netfix apply"
assert_true "says that glu changed nothing" contains "$output" "glu changed nothing"

netfix_state yes yes no
output=$(warnings)
assert_true "warns when the rule is active but not saved" contains "$output" "not saved"

netfix_state yes yes yes
assert_eq "$(warnings)" "" "no warning when the rule is active and saved"

netfix_state no no no
assert_eq "$(warnings)" "" "no warning when the rule is not needed"

netfix_state no yes yes
assert_eq "$(warnings)" "" "no warning when the rule exists but is not needed"

STUB_STATUS=1
netfix_state yes no no
assert_eq "$(warnings)" "" "no warning when the router state cannot be read"
assert_true "a failed state read does not fail the update" tailscale_warn_port_forward_conflict

assert_done
