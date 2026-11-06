#!/bin/sh
set -eu

TS_DAEMON=/usr/sbin/tailscaled
TS_CLIENT=/usr/sbin/tailscale
TS_CONFIG=/etc/config/tailscale
TS_INIT=/etc/init.d/tailscale
GL_TAILSCALE=/usr/bin/gl_tailscale
AGH_BINARY=/usr/bin/AdGuardHome
AGH_CONFIG=/etc/AdGuardHome/config.yaml
AGH_INIT=/etc/init.d/adguardhome
ROM_ROOT=${GLU_ROM_ROOT:-/rom}
SYSUPGRADE_CONF=${GLU_SYSUPGRADE_CONF:-/etc/sysupgrade.conf}
BACKUP_ROOT=${GLU_BACKUP_ROOT:-/root/glu-backups}
BACKUP_KEEP=2
LOCK_FILE=/tmp/glu.lock
NETFIX_SECTION=pf_reply_main
NETFIX_PRIORITY=5990
NETFIX_MARK=0x10000/0xfff000
HEALTH_TIMEOUT=60

say() {
  printf '  router: %s\n' "$*" >&2
  logger -t glu -- "$*" 2>/dev/null || true
}

fail() {
  say "error: $*"
  exit 1
}

yes_no() {
  if "$@"; then echo yes; else echo no; fi
}

hold_lock() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || fail "another glu run is active on this router"
}

normalize_version() {
  printf '%s\n' "$1" | sed -e 's/^v//' -e 's/^\([0-9][0-9.]*[0-9]\).*/\1/'
}

is_little_endian() {
  [ "$(hexdump -s 5 -n 1 -e '1/1 "%u"' /bin/busybox)" = 1 ]
}

machine_arch() {
  case $(uname -m) in
    aarch64 | arm64) echo "arm64 linux_arm64" ;;
    armv7* | armv8l) echo "arm linux_armv7" ;;
    x86_64) echo "amd64 linux_amd64" ;;
    i386 | i686) echo "386 linux_386" ;;
    mips)
      if is_little_endian; then
        echo "mipsle linux_mipsle_softfloat"
      else
        echo "mips linux_mips_softfloat"
      fi
      ;;
    *) echo " " ;;
  esac
}

binary_version() {
  [ -x "$1" ] || return 0
  "$1" --version 2>/dev/null | head -n 1 | sed -e 's/^AdGuard Home, version //' -e 's/^v//' || true
}

free_kb() {
  df -Pk "$1" | awk 'NR == 2 { print $4 }'
}

size_kb() {
  du -k "$@" 2>/dev/null | awk '{ total += $1 } END { print total + 0 }'
}

need_space_kb() {
  local available
  available=$(free_kb "$1")
  [ "$available" -ge "$2" ] || fail "not enough free space on $1: need $2 KB, have $available KB"
}

uci_value() {
  uci -q get "$1" 2>/dev/null || true
}

tailscale_state() {
  [ -x "$TS_CLIENT" ] || return 0
  timeout 5 "$TS_CLIENT" status --json 2>/dev/null | jsonfilter -e '@.BackendState' 2>/dev/null || true
}

tailscale_has_connmark() {
  nft list table ip mangle 2>/dev/null | grep -q 'ct mark & 0x00ff0000' && return 0
  iptables-save -t mangle 2>/dev/null | grep -q 'CONNMARK.*0xff0000'
}

vpn_drops_unmarked_lan() {
  ip rule 2>/dev/null | grep -q 'iif br-lan blackhole'
}

port_forward_count() {
  local count
  count=$(grep -c '^Rule #' /proc/port_forward_rules 2>/dev/null) || true
  echo "${count:-0}"
}

netfix_live() {
  ip rule 2>/dev/null | grep -q "^$NETFIX_PRIORITY:.*fwmark $NETFIX_MARK lookup main"
}

netfix_saved() {
  [ "$(uci_value "network.$NETFIX_SECTION.mark")" = "$NETFIX_MARK" ]
}

netfix_needed() {
  vpn_drops_unmarked_lan && tailscale_has_connmark && [ "$(port_forward_count)" -gt 0 ]
}

is_persisted() {
  grep -qxF "$1" "$SYSUPGRADE_CONF" 2>/dev/null
}

persist_add() {
  local path
  touch "$SYSUPGRADE_CONF"
  if [ -s "$SYSUPGRADE_CONF" ] && [ -n "$(tail -c 1 "$SYSUPGRADE_CONF")" ]; then
    echo >>"$SYSUPGRADE_CONF"
  fi
  for path in "$@"; do
    is_persisted "$path" || echo "$path" >>"$SYSUPGRADE_CONF"
  done
}

persist_remove() {
  local path
  [ -f "$SYSUPGRADE_CONF" ] || return 0
  for path in "$@"; do
    grep -vxF "$path" "$SYSUPGRADE_CONF" >"$SYSUPGRADE_CONF.glu-new" || true
    mv -f "$SYSUPGRADE_CONF.glu-new" "$SYSUPGRADE_CONF"
  done
}

gl_patch_state() {
  if [ ! -f "$GL_TAILSCALE" ]; then
    echo none
  elif grep -q -- '--stateful-filtering=false' "$GL_TAILSCALE"; then
    echo applied
  elif grep -q 'param="--advertise-routes=$routes"' "$GL_TAILSCALE"; then
    echo missing
  else
    echo unknown
  fi
}

gl_patch_apply() {
  case $(gl_patch_state) in
    missing)
      cp -p "$GL_TAILSCALE" "$GL_TAILSCALE.glu-new"
      sed 's/param="--advertise-routes=$routes"/param="--advertise-routes=$routes --stateful-filtering=false"/' "$GL_TAILSCALE" >"$GL_TAILSCALE.glu-new"
      mv -f "$GL_TAILSCALE.glu-new" "$GL_TAILSCALE"
      say "added --stateful-filtering=false to gl_tailscale for subnet and exit-node traffic"
      ;;
    unknown)
      say "gl_tailscale has an unknown layout; the stateful-filtering change was skipped"
      ;;
  esac
}

install_file() {
  cp "$1" "$2.glu-new"
  chmod 0755 "$2.glu-new"
  mv -f "$2.glu-new" "$2"
}

backup_create() {
  local component directory path name
  component=$1
  shift
  directory="$BACKUP_ROOT/$component/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$directory"
  : >"$directory/MANIFEST"
  for path in "$@"; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    name=$(printf '%s' "$path" | tr / _)
    cp -a "$path" "$directory/$name"
    printf '%s %s\n' "$name" "$path" >>"$directory/MANIFEST"
  done
  echo "$directory"
}

backup_latest() {
  local candidate latest
  latest=''
  for candidate in "$BACKUP_ROOT/$1"/*; do
    [ -f "$candidate/MANIFEST" ] && latest=$candidate
  done
  echo "$latest"
}

backup_restore() {
  local name path
  [ -f "$1/MANIFEST" ] || fail "backup is incomplete: $1"
  while read -r name path; do
    cp -a "$1/$name" "$path.glu-new"
    mv -f "$path.glu-new" "$path"
  done <"$1/MANIFEST"
}

backup_prune() {
  local candidate count
  count=0
  for candidate in "$BACKUP_ROOT/$1"/*; do
    [ -d "$candidate" ] && count=$((count + 1))
  done
  for candidate in "$BACKUP_ROOT/$1"/*; do
    [ "$count" -le "$BACKUP_KEEP" ] && break
    [ -d "$candidate" ] || continue
    rm -rf "$candidate"
    count=$((count - 1))
  done
}

verify_package() {
  local actual
  [ -f "$1" ] || fail "package not found: $1"
  actual=$(sha256sum "$1" | cut -d ' ' -f 1)
  [ "$actual" = "$2" ] || fail "package checksum changed on the way to the router"
}

stage_dir() {
  local directory
  directory="$(dirname "$1")/stage-$2"
  rm -rf "$directory"
  mkdir -p "$directory"
  echo "$directory"
}

tailscale_wait_state() {
  local waited state
  waited=0
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    state=$(tailscale_state)
    if [ "$1" = any ] && [ -n "$state" ]; then
      return 0
    fi
    [ "$state" = "$1" ] && return 0
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

tailscale_start_and_check() {
  local wanted
  wanted=$1
  [ "$(uci_value tailscale.settings.enabled)" = 1 ] || return 0
  "$TS_INIT" start >/dev/null 2>&1 || true
  tailscale_wait_state "$wanted"
}

adguard_healthy() {
  local pid answer
  pid=$(pidof AdGuardHome) || return 1
  netstat -lnup 2>/dev/null | grep -q " $pid/AdGuardHome" || return 1
  answer=$(nslookup "glu-check-$(date +%s).example.com" 127.0.0.1 2>&1) || true
  case $answer in
    *"timed out"* | *"no servers"* | *"connection refused"*) return 1 ;;
  esac
  return 0
}

adguard_wait_healthy() {
  local waited streak
  waited=0
  streak=0
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    if adguard_healthy; then
      streak=$((streak + 1))
      [ "$streak" -ge 2 ] && return 0
    else
      streak=0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

adguard_start_and_check() {
  [ "$(uci_value adguardhome.config.enabled)" = 1 ] || return 0
  "$AGH_INIT" start >/dev/null 2>&1 || true
  adguard_wait_healthy
}

cmd_facts() {
  local arch
  arch=$(machine_arch)
  echo "router.model=$(cat /tmp/sysinfo/model 2>/dev/null || true)"
  echo "router.firmware=$(cat /etc/glversion 2>/dev/null || true)"
  echo "arch.tailscale=${arch% *}"
  echo "arch.adguard=${arch#* }"
  echo "tailscale.version=$(normalize_version "$(binary_version "$TS_DAEMON")")"
  echo "tailscale.firmware_version=$(normalize_version "$(binary_version "$ROM_ROOT$TS_DAEMON")")"
  echo "tailscale.enabled=$(uci_value tailscale.settings.enabled)"
  echo "tailscale.state=$(tailscale_state)"
  echo "tailscale.persisted=$(yes_no is_persisted "$TS_DAEMON")"
  echo "tailscale.gl_patch=$(gl_patch_state)"
  echo "tailscale.connmark=$(yes_no tailscale_has_connmark)"
  echo "adguard.version=$(normalize_version "$(binary_version "$AGH_BINARY")")"
  echo "adguard.firmware_version=$(normalize_version "$(binary_version "$ROM_ROOT$AGH_BINARY")")"
  echo "adguard.enabled=$(uci_value adguardhome.config.enabled)"
  echo "adguard.persisted=$(yes_no is_persisted "$AGH_BINARY")"
  echo "vpn.drops_unmarked_lan=$(yes_no vpn_drops_unmarked_lan)"
  echo "portforward.rules=$(port_forward_count)"
  echo "netfix.needed=$(yes_no netfix_needed)"
  echo "netfix.live=$(yes_no netfix_live)"
  echo "netfix.saved=$(yes_no netfix_saved)"
  echo "space.tmp_kb=$(free_kb /tmp)"
  echo "space.overlay_kb=$(free_kb /overlay)"
}

cmd_install_tailscale() {
  local package sha256 version dry_run gl_patch option ts_arch stage new_dir new_version prior_state backup
  [ $# -ge 3 ] || fail "usage: install-tailscale PACKAGE SHA256 VERSION [--dry-run] [--no-gl-patch]"
  package=$1
  sha256=$2
  version=$3
  shift 3
  dry_run=0
  gl_patch=1
  for option in "$@"; do
    case $option in
      --dry-run) dry_run=1 ;;
      --no-gl-patch) gl_patch=0 ;;
      *) fail "unknown option: $option" ;;
    esac
  done

  hold_lock
  verify_package "$package" "$sha256"
  ts_arch=$(machine_arch)
  ts_arch=${ts_arch% *}
  stage=$(stage_dir "$package" tailscale)
  tar -xzf "$package" -C "$stage"
  new_dir="$stage/tailscale_${version}_${ts_arch}"
  [ -x "$new_dir/tailscaled" ] && [ -x "$new_dir/tailscale" ] || fail "the package does not contain tailscale and tailscaled for $ts_arch"
  new_version=$(normalize_version "$(binary_version "$new_dir/tailscaled")")
  [ "$new_version" = "$version" ] || fail "the package reports version '$new_version', expected $version"
  say "package contains Tailscale $new_version for $ts_arch and runs on this router"
  need_space_kb /overlay $(($(size_kb "$new_dir/tailscaled" "$new_dir/tailscale" "$TS_DAEMON" "$TS_CLIENT") + 2048))

  if [ "$dry_run" = 1 ]; then
    say "dry run: the package is valid and fits; nothing was changed"
    return 0
  fi

  prior_state=$(tailscale_state)
  backup=$(backup_create tailscale "$TS_DAEMON" "$TS_CLIENT" "$TS_CONFIG" "$GL_TAILSCALE")
  say "backup saved in $backup"
  "$TS_INIT" stop >/dev/null 2>&1 || true
  install_file "$new_dir/tailscaled" "$TS_DAEMON"
  install_file "$new_dir/tailscale" "$TS_CLIENT"
  [ "$gl_patch" = 1 ] && gl_patch_apply
  persist_add "$TS_DAEMON" "$TS_CLIENT" "$TS_CONFIG"

  [ "$prior_state" = Running ] || prior_state=any
  if ! tailscale_start_and_check "$prior_state"; then
    say "Tailscale did not reach state '$prior_state'; restoring the previous version"
    "$TS_INIT" stop >/dev/null 2>&1 || true
    backup_restore "$backup"
    tailscale_start_and_check any || true
    fail "the update failed and was rolled back"
  fi
  backup_prune tailscale
  say "Tailscale $(normalize_version "$(binary_version "$TS_DAEMON")") is installed (state: $(tailscale_state))"
}

cmd_restore_tailscale() {
  local source backup
  source=${1:-backup}
  hold_lock
  case $source in
    backup)
      backup=$(backup_latest tailscale)
      [ -n "$backup" ] || fail "no Tailscale backup in $BACKUP_ROOT/tailscale"
      "$TS_INIT" stop >/dev/null 2>&1 || true
      backup_restore "$backup"
      say "restored files from $backup"
      ;;
    firmware)
      [ -x "$ROM_ROOT$TS_DAEMON" ] || fail "the firmware has no tailscaled in $ROM_ROOT"
      backup=$(backup_create tailscale "$TS_DAEMON" "$TS_CLIENT" "$TS_CONFIG" "$GL_TAILSCALE")
      say "backup of the current version saved in $backup"
      "$TS_INIT" stop >/dev/null 2>&1 || true
      install_file "$ROM_ROOT$TS_DAEMON" "$TS_DAEMON"
      rm -f "$TS_CLIENT"
      if [ -L "$ROM_ROOT$TS_CLIENT" ]; then
        ln -s "$(readlink "$ROM_ROOT$TS_CLIENT")" "$TS_CLIENT"
      else
        install_file "$ROM_ROOT$TS_CLIENT" "$TS_CLIENT"
      fi
      [ -f "$ROM_ROOT$GL_TAILSCALE" ] && install_file "$ROM_ROOT$GL_TAILSCALE" "$GL_TAILSCALE"
      persist_remove "$TS_DAEMON" "$TS_CLIENT" "$GL_TAILSCALE"
      backup_prune tailscale
      ;;
    *) fail "unknown restore source '$source'; use backup or firmware" ;;
  esac
  tailscale_start_and_check any || fail "Tailscale did not start after the restore"
  say "Tailscale $(normalize_version "$(binary_version "$TS_DAEMON")") is active (state: $(tailscale_state))"
}

cmd_install_adguard() {
  local package sha256 version dry_run option stage new_binary new_version backup
  [ $# -ge 3 ] || fail "usage: install-adguard PACKAGE SHA256 VERSION [--dry-run]"
  package=$1
  sha256=$2
  version=$3
  shift 3
  dry_run=0
  for option in "$@"; do
    case $option in
      --dry-run) dry_run=1 ;;
      *) fail "unknown option: $option" ;;
    esac
  done

  hold_lock
  verify_package "$package" "$sha256"
  stage=$(stage_dir "$package" adguard)
  tar -xzf "$package" -C "$stage"
  new_binary="$stage/AdGuardHome/AdGuardHome"
  [ -x "$new_binary" ] || fail "the package does not contain AdGuardHome/AdGuardHome"
  new_version=$(normalize_version "$(binary_version "$new_binary")")
  [ "$new_version" = "$version" ] || fail "the package reports version '$new_version', expected $version"
  "$new_binary" --help 2>&1 | grep -q -- '--glinet' || fail "this build has no --glinet option, which the GL.iNet start script needs"
  say "package contains AdGuard Home $new_version with GL.iNet support and runs on this router"
  need_space_kb /overlay $(($(size_kb "$new_binary" "$AGH_BINARY" "$AGH_CONFIG") + 2048))

  if [ "$dry_run" = 1 ]; then
    say "dry run: the package is valid and fits; nothing was changed"
    return 0
  fi

  backup=$(backup_create adguard "$AGH_BINARY" "$AGH_CONFIG")
  say "backup saved in $backup"
  "$AGH_INIT" stop >/dev/null 2>&1 || true
  install_file "$new_binary" "$AGH_BINARY"
  persist_add "$AGH_BINARY"

  if ! adguard_start_and_check; then
    say "AdGuard Home did not become healthy; restoring the previous version and config"
    "$AGH_INIT" stop >/dev/null 2>&1 || true
    backup_restore "$backup"
    adguard_start_and_check || true
    fail "the update failed and was rolled back"
  fi
  backup_prune adguard
  say "AdGuard Home $(normalize_version "$(binary_version "$AGH_BINARY")") is installed and answers DNS"
}

cmd_restore_adguard() {
  local source backup
  source=${1:-backup}
  hold_lock
  case $source in
    backup)
      backup=$(backup_latest adguard)
      [ -n "$backup" ] || fail "no AdGuard Home backup in $BACKUP_ROOT/adguard"
      "$AGH_INIT" stop >/dev/null 2>&1 || true
      backup_restore "$backup"
      say "restored binary and config from $backup"
      ;;
    firmware)
      [ -x "$ROM_ROOT$AGH_BINARY" ] || fail "the firmware has no AdGuardHome in $ROM_ROOT"
      backup=$(backup_create adguard "$AGH_BINARY" "$AGH_CONFIG")
      say "backup of the current version saved in $backup"
      "$AGH_INIT" stop >/dev/null 2>&1 || true
      install_file "$ROM_ROOT$AGH_BINARY" "$AGH_BINARY"
      persist_remove "$AGH_BINARY"
      backup_prune adguard
      ;;
    *) fail "unknown restore source '$source'; use backup or firmware" ;;
  esac
  adguard_start_and_check || fail "AdGuard Home is not healthy after the restore; try 'restore backup'"
  say "AdGuard Home $(normalize_version "$(binary_version "$AGH_BINARY")") is active"
}

cmd_netfix() {
  case ${1:-status} in
    status)
      echo "netfix.needed=$(yes_no netfix_needed)"
      echo "netfix.live=$(yes_no netfix_live)"
      echo "netfix.saved=$(yes_no netfix_saved)"
      ;;
    apply)
      hold_lock
      if ! netfix_live; then
        while ip rule del priority "$NETFIX_PRIORITY" 2>/dev/null; do :; done
        ip rule add fwmark "$NETFIX_MARK" lookup main priority "$NETFIX_PRIORITY"
      fi
      uci set "network.$NETFIX_SECTION=rule"
      uci set "network.$NETFIX_SECTION.mark=$NETFIX_MARK"
      uci set "network.$NETFIX_SECTION.lookup=main"
      uci set "network.$NETFIX_SECTION.priority=$NETFIX_PRIORITY"
      uci commit network
      say "rule $NETFIX_PRIORITY (fwmark $NETFIX_MARK lookup main) is active and saved"
      ;;
    remove)
      hold_lock
      while ip rule del fwmark "$NETFIX_MARK" lookup main priority "$NETFIX_PRIORITY" 2>/dev/null; do :; done
      uci -q delete "network.$NETFIX_SECTION" || true
      uci commit network
      say "rule $NETFIX_PRIORITY is removed"
      ;;
    *) fail "unknown netfix action '$1'; use status, apply or remove" ;;
  esac
}

doctor_line() {
  printf '%-5s %s\n' "$1" "$2"
}

cmd_doctor() {
  local url problems state code
  url=${1:-}
  problems=0

  if [ "$(uci_value tailscale.settings.enabled)" = 1 ]; then
    state=$(tailscale_state)
    if [ "$state" = Running ]; then
      doctor_line ok "Tailscale $(normalize_version "$(binary_version "$TS_DAEMON")") is running"
    else
      doctor_line FAIL "Tailscale is enabled but its state is '${state:-unknown}'"
      problems=$((problems + 1))
    fi
    [ "$(gl_patch_state)" = missing ] && doctor_line warn "gl_tailscale has no --stateful-filtering=false; subnet or exit-node traffic can fail"
  else
    doctor_line info "Tailscale is disabled"
  fi

  if [ "$(uci_value adguardhome.config.enabled)" = 1 ]; then
    if adguard_healthy; then
      doctor_line ok "AdGuard Home $(normalize_version "$(binary_version "$AGH_BINARY")") is running and DNS answers"
    else
      doctor_line FAIL "AdGuard Home is enabled but not healthy"
      problems=$((problems + 1))
    fi
  else
    doctor_line info "AdGuard Home is disabled"
  fi

  if netfix_needed; then
    if netfix_live && netfix_saved; then
      doctor_line ok "port-forward reply rule $NETFIX_PRIORITY is active and saved (VPN + Tailscale + port forwards)"
    else
      doctor_line FAIL "VPN, Tailscale and port forwards are active but rule $NETFIX_PRIORITY is missing; run: glu netfix apply"
      problems=$((problems + 1))
    fi
  else
    doctor_line info "port-forward reply rule not needed now (vpn=$(yes_no vpn_drops_unmarked_lan), tailscale connmark=$(yes_no tailscale_has_connmark), port forwards=$(port_forward_count)); present=$(yes_no netfix_live)"
  fi

  if [ "$(normalize_version "$(binary_version "$TS_DAEMON")")" != "$(normalize_version "$(binary_version "$ROM_ROOT$TS_DAEMON")")" ] && ! is_persisted "$TS_DAEMON"; then
    doctor_line warn "Tailscale differs from the firmware copy but is not kept on firmware upgrades"
  fi
  if [ "$(normalize_version "$(binary_version "$AGH_BINARY")")" != "$(normalize_version "$(binary_version "$ROM_ROOT$AGH_BINARY")")" ] && ! is_persisted "$AGH_BINARY"; then
    doctor_line warn "AdGuard Home differs from the firmware copy but is not kept on firmware upgrades"
  fi

  if [ -n "$url" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$url" 2>/dev/null) || true
    case $code in
      52[24]) doctor_line FAIL "$url -> HTTP $code: the origin did not answer in time (reply path problem)" ;;
      52[56]) doctor_line FAIL "$url -> HTTP $code: TLS problem between Cloudflare and the origin" ;;
      52[0137]) doctor_line FAIL "$url -> HTTP $code: the origin refused or broke the connection" ;;
      000 | '') doctor_line FAIL "$url -> no HTTP answer" ;;
      *) doctor_line ok "$url -> HTTP $code (the request reached the origin)" ;;
    esac
    case $code in
      52? | 000 | '') problems=$((problems + 1)) ;;
    esac
  fi

  [ "$problems" -eq 0 ]
}

main() {
  [ $# -ge 1 ] || fail "usage: agent.sh COMMAND [ARGS]"
  command=$1
  shift
  case $command in
    facts) cmd_facts ;;
    install-tailscale) cmd_install_tailscale "$@" ;;
    restore-tailscale) cmd_restore_tailscale "$@" ;;
    install-adguard) cmd_install_adguard "$@" ;;
    restore-adguard) cmd_restore_adguard "$@" ;;
    gl-patch)
      hold_lock
      gl_patch_apply
      echo "tailscale.gl_patch=$(gl_patch_state)"
      ;;
    netfix) cmd_netfix "$@" ;;
    doctor) cmd_doctor "$@" ;;
    *) fail "unknown command: $command" ;;
  esac
}

[ "${GLU_AGENT_LIBRARY:-0}" = 1 ] || main "$@"
