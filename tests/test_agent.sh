#!/bin/sh
set -u

REPO_ROOT=$1
. "$REPO_ROOT/tests/lib_assert.sh"

TEST_TMP=$(mktemp -d /tmp/glu-test.XXXXXX)
trap 'rm -rf "$TEST_TMP"' EXIT

GLU_AGENT_LIBRARY=1
GLU_SYSUPGRADE_CONF="$TEST_TMP/sysupgrade.conf"
GLU_BACKUP_ROOT="$TEST_TMP/backups"
. "$REPO_ROOT/agent/agent.sh"
set +e

say() {
  :
}

assert_eq "$(normalize_version 1.104.4-t938213198-gd38c96d6a)" "1.104.4" "agent normalize_version removes the build suffix"
assert_eq "$(normalize_version v0.107.80)" "0.107.80" "agent normalize_version removes the v prefix"

printf '/etc/config/gl_nas/' >"$SYSUPGRADE_CONF"
persist_add /usr/sbin/tailscaled /usr/sbin/tailscale
persist_add /usr/sbin/tailscaled
assert_eq "$(cat "$SYSUPGRADE_CONF")" "$(printf '/etc/config/gl_nas/\n/usr/sbin/tailscaled\n/usr/sbin/tailscale')" "persist_add adds a newline first and no duplicates"
persist_remove /usr/sbin/tailscale
assert_eq "$(cat "$SYSUPGRADE_CONF")" "$(printf '/etc/config/gl_nas/\n/usr/sbin/tailscaled')" "persist_remove removes only the exact line"
assert_true "is_persisted finds an exact line" is_persisted /usr/sbin/tailscaled
assert_false "is_persisted ignores a prefix" is_persisted /usr/sbin/tail

GL_TAILSCALE="$TEST_TMP/gl_tailscale"
printf '%s\n' '        if [ -n "$routes" ]; then' '            param="--advertise-routes=$routes"' '        fi' >"$GL_TAILSCALE"
assert_eq "$(gl_patch_state)" missing "gl_patch_state detects the firmware line"
gl_patch_apply
assert_eq "$(gl_patch_state)" applied "gl_patch_apply adds the flag"
gl_patch_apply
assert_eq "$(grep -c -- '--stateful-filtering=false' "$GL_TAILSCALE")" 1 "gl_patch_apply runs safely two times"
printf 'echo other layout\n' >"$GL_TAILSCALE"
assert_eq "$(gl_patch_state)" unknown "gl_patch_state reports an unknown layout"
GL_TAILSCALE="$TEST_TMP/absent"
assert_eq "$(gl_patch_state)" none "gl_patch_state reports a missing file"

mkdir -p "$TEST_TMP/live"
printf 'old daemon' >"$TEST_TMP/live/tailscaled"
ln -s tailscaled "$TEST_TMP/live/tailscale"
mkdir -p "$BACKUP_ROOT/tailscale/20000101-000000" "$BACKUP_ROOT/tailscale/20000102-000000"
: >"$BACKUP_ROOT/tailscale/20000101-000000/MANIFEST"
: >"$BACKUP_ROOT/tailscale/20000102-000000/MANIFEST"
backup=$(backup_create tailscale "$TEST_TMP/live/tailscaled" "$TEST_TMP/live/tailscale" "$TEST_TMP/live/absent")
printf 'new daemon' >"$TEST_TMP/live/tailscaled"
rm "$TEST_TMP/live/tailscale"
printf 'new client' >"$TEST_TMP/live/tailscale"
backup_restore "$backup"
assert_eq "$(cat "$TEST_TMP/live/tailscaled")" "old daemon" "backup_restore puts back the old file"
assert_true "backup_restore puts back the symlink" [ -L "$TEST_TMP/live/tailscale" ]
assert_eq "$(wc -l <"$backup/MANIFEST" | tr -d ' ')" 2 "backup_create skips files that do not exist"
assert_eq "$(backup_latest tailscale)" "$backup" "backup_latest returns the newest backup"
backup_prune tailscale
remaining=0
for entry in "$BACKUP_ROOT/tailscale"/*; do
  [ -d "$entry" ] && remaining=$((remaining + 1))
done
assert_eq "$remaining" 2 "backup_prune keeps two backups"
assert_true "backup_prune keeps the newest backup" [ -d "$backup" ]
assert_false "backup_prune removes the oldest backup" [ -d "$BACKUP_ROOT/tailscale/20000101-000000" ]

if ! command -v sha256sum >/dev/null 2>&1; then
  sha256sum() {
    shasum -a 256 "$@"
  }
fi

package_check() {
  (verify_package "$TEST_TMP/package" "$1") 2>/dev/null
}

printf 'payload' >"$TEST_TMP/package"
package_sha=$(sha256sum "$TEST_TMP/package" | cut -d ' ' -f 1)
assert_true "verify_package accepts the right checksum" package_check "$package_sha"
assert_false "verify_package rejects a wrong checksum" package_check 0000

assert_done
