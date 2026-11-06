ASSERT_FAILURES=0

assert_pass() {
  printf '  pass  %s\n' "$1"
}

assert_fail() {
  printf '  FAIL  %s\n' "$1"
  ASSERT_FAILURES=$((ASSERT_FAILURES + 1))
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    assert_pass "$3"
  else
    assert_fail "$3: got [$1], want [$2]"
  fi
}

assert_true() {
  assert_label=$1
  shift
  if "$@"; then assert_pass "$assert_label"; else assert_fail "$assert_label"; fi
}

assert_false() {
  assert_label=$1
  shift
  if "$@"; then assert_fail "$assert_label"; else assert_pass "$assert_label"; fi
}

assert_done() {
  [ "$ASSERT_FAILURES" -eq 0 ]
}
