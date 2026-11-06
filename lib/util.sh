require_commands() {
  for required_command in "$@"; do
    command -v "$required_command" >/dev/null 2>&1 || die "missing required command: $required_command"
  done
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

normalize_version() {
  printf '%s\n' "$1" | sed -E 's/^v//; s/^([0-9]+(\.[0-9]+)*).*/\1/'
}

version_gt() {
  awk -v left="$(normalize_version "$1")" -v right="$(normalize_version "$2")" '
    BEGIN {
      left_count = split(left, l, ".")
      right_count = split(right, r, ".")
      count = left_count > right_count ? left_count : right_count
      for (i = 1; i <= count; i++) {
        lv = (i <= left_count) ? l[i] + 0 : 0
        rv = (i <= right_count) ? r[i] + 0 : 0
        if (lv > rv) exit 0
        if (lv < rv) exit 1
      }
      exit 1
    }'
}

version_eq() {
  [ "$(normalize_version "$1")" = "$(normalize_version "$2")" ]
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

json_value() {
  python3 -I -c '
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    value = value[key]
print(value)
' "$1" "$2"
}

workdir_create() {
  GLU_WORKDIR=$(mktemp -d /tmp/glu.XXXXXX) || die "cannot create a work directory"
  trap workdir_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

workdir_cleanup() {
  cleanup_status=$?
  remote_close 2>/dev/null || true
  [ -n "${GLU_WORKDIR:-}" ] && rm -rf "$GLU_WORKDIR"
  exit "$cleanup_status"
}
