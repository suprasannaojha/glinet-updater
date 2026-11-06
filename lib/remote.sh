REMOTE_DIR=''
REMOTE_SOCKET=''

remote_ssh() {
  ssh -o ControlMaster=auto -o ControlPath="$REMOTE_SOCKET" -o ControlPersist=120 \
    -o ConnectTimeout=10 -o ServerAliveInterval=15 "$GLU_ROUTER" "$@"
}

remote_open() {
  [ -n "$REMOTE_DIR" ] && return 0
  REMOTE_SOCKET="$GLU_WORKDIR/ssh.sock"
  REMOTE_DIR=$(remote_ssh "mktemp -d /tmp/glu-session.XXXXXX" </dev/null) || die "cannot open an SSH session to $GLU_ROUTER"
  case $REMOTE_DIR in
    /tmp/glu-session.*) ;;
    *) die "the router returned an unexpected work directory: $REMOTE_DIR" ;;
  esac
  remote_push "$GLU_ROOT/agent/agent.sh" agent.sh
}

remote_close() {
  [ -n "$REMOTE_DIR" ] || return 0
  remote_ssh "rm -rf $REMOTE_DIR" </dev/null >/dev/null 2>&1 || true
  ssh -o ControlPath="$REMOTE_SOCKET" -O exit "$GLU_ROUTER" >/dev/null 2>&1 || true
  REMOTE_DIR=''
}

remote_push() {
  remote_ssh "cat > $REMOTE_DIR/$2" <"$1" || die "cannot copy $2 to the router"
}

remote_path() {
  printf '%s/%s\n' "$REMOTE_DIR" "$1"
}

remote_agent() {
  remote_open
  remote_command="sh $REMOTE_DIR/agent.sh"
  for remote_arg in "$@"; do
    remote_command="$remote_command $(shell_quote "$remote_arg")"
  done
  remote_ssh "$remote_command" </dev/null
}

remote_facts() {
  [ -n "${GLU_FACTS:-}" ] && return 0
  remote_open
  remote_agent facts >"$GLU_WORKDIR/facts" || die "cannot read the router state"
  GLU_FACTS="$GLU_WORKDIR/facts"
}

fact() {
  [ -n "${GLU_FACTS:-}" ] || die "internal error: call remote_facts before fact"
  sed -n "s/^$1=//p" "$GLU_FACTS" | head -n 1
}
