if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  UI_BOLD=$(printf '\033[1m')
  UI_RED=$(printf '\033[31m')
  UI_GREEN=$(printf '\033[32m')
  UI_YELLOW=$(printf '\033[33m')
  UI_RESET=$(printf '\033[0m')
else
  UI_BOLD=''
  UI_RED=''
  UI_GREEN=''
  UI_YELLOW=''
  UI_RESET=''
fi

info() {
  printf '%s==>%s %s\n' "$UI_BOLD" "$UI_RESET" "$*" >&2
}

ok() {
  printf '%s ok%s  %s\n' "$UI_GREEN" "$UI_RESET" "$*" >&2
}

warn() {
  printf '%swarn%s %s\n' "$UI_YELLOW" "$UI_RESET" "$*" >&2
}

die() {
  printf '%serror%s %s\n' "$UI_RED" "$UI_RESET" "$*" >&2
  exit 1
}

confirm() {
  [ "${GLU_ASSUME_YES:-0}" = 1 ] && return 0
  [ -t 0 ] || die "confirmation needed but stdin is not a terminal; rerun with --yes"
  printf '%s [y/N] ' "$1" >&2
  read -r confirm_answer || return 1
  case $confirm_answer in
    y | Y | yes | YES) return 0 ;;
  esac
  return 1
}
