TS_PKGS_URL=https://pkgs.tailscale.com
TS_TRACK=stable

tailscale_resolve_target() {
  remote_facts
  ts_arch=$(fact arch.tailscale)
  [ -n "$ts_arch" ] || die "the router reported no Tailscale architecture"
  if [ -n "${GLU_TARGET_VERSION:-}" ]; then
    TS_TARGET_VERSION=$(normalize_version "$GLU_TARGET_VERSION")
    TS_TARBALL="tailscale_${TS_TARGET_VERSION}_${ts_arch}.tgz"
    return 0
  fi
  ts_index="$GLU_WORKDIR/tailscale-index.json"
  fetch_to "$TS_PKGS_URL/$TS_TRACK/?mode=json" "$ts_index"
  TS_TARGET_VERSION=$(json_value "$ts_index" TarballsVersion) || die "cannot read the Tailscale release index"
  TS_TARBALL=$(json_value "$ts_index" "Tarballs.$ts_arch") || die "Tailscale has no tarball for $ts_arch"
}

tailscale_download_verified() {
  ts_dir="$GLU_WORKDIR/tailscale"
  mkdir -p "$ts_dir"
  info "Downloading $TS_TARBALL from $TS_PKGS_URL"
  fetch_to "$TS_PKGS_URL/$TS_TRACK/$TS_TARBALL" "$ts_dir/$TS_TARBALL" "$FETCH_MAX_PACKAGE_BYTES"
  fetch_to "$TS_PKGS_URL/$TS_TRACK/$TS_TARBALL.sig" "$ts_dir/$TS_TARBALL.sig"
  fetch_to "$TS_PKGS_URL/$TS_TRACK/$TS_TARBALL.sha256" "$ts_dir/$TS_TARBALL.sha256"
  fetch_to "$TS_PKGS_URL/distsign.pub" "$ts_dir/distsign.pub"
  fetch_to "$TS_PKGS_URL/distsign.pub.sig" "$ts_dir/distsign.pub.sig"

  python3 -I "$GLU_ROOT/tools/distsign_verify.py" \
    --roots "$GLU_ROOT/keys/tailscale" \
    --signing-keys "$ts_dir/distsign.pub" \
    --signing-keys-sig "$ts_dir/distsign.pub.sig" \
    --package "$ts_dir/$TS_TARBALL" \
    --package-sig "$ts_dir/$TS_TARBALL.sig" >/dev/null || die "Tailscale package signature is NOT valid; nothing was installed"
  ok "signature verified with the pinned Tailscale root keys"

  TS_SHA256=$(sha256_of "$ts_dir/$TS_TARBALL")
  ts_vendor_sha256=$(tr -d ' \n' <"$ts_dir/$TS_TARBALL.sha256")
  [ "$TS_SHA256" = "$ts_vendor_sha256" ] || die "Tailscale checksum does not match the vendor checksum"
  ok "sha256 $TS_SHA256"
  TS_PACKAGE="$ts_dir/$TS_TARBALL"
}

tailscale_ensure_gl_patch() {
  [ "${GLU_GL_PATCH:-1}" = 1 ] || return 0
  [ "$(fact tailscale.gl_patch)" = missing ] || return 0
  if [ "${GLU_DRY_RUN:-0}" = 1 ]; then
    warn "gl_tailscale needs --stateful-filtering=false; run without --dry-run to add it"
    return 0
  fi
  remote_agent gl-patch >/dev/null
  ok "added --stateful-filtering=false to gl_tailscale"
}

tailscale_warn_port_forward_conflict() {
  ts_netfix=$(remote_agent netfix status) || return 0
  printf '%s\n' "$ts_netfix" | grep -qx 'netfix.needed=yes' || return 0
  if ! printf '%s\n' "$ts_netfix" | grep -qx 'netfix.live=yes'; then
    warn "port forwards can fail on this router: a VPN client, Tailscale connection marks and port forwards are all active"
    warn "replies from LAN servers are dropped (Cloudflare shows error 522); glu changed nothing for this"
    warn "to add the reply rule, run: glu netfix apply (see README, 'The port-forward fix')"
  elif ! printf '%s\n' "$ts_netfix" | grep -qx 'netfix.saved=yes'; then
    warn "the port-forward reply rule is active but not saved, so a reboot removes it"
    warn "to save it, run: glu netfix apply"
  fi
}

tailscale_update() {
  remote_facts
  ts_current=$(fact tailscale.version)
  tailscale_resolve_target
  info "Tailscale on router: ${ts_current:-not installed}, target: $TS_TARGET_VERSION"
  if [ "${GLU_FORCE:-0}" != 1 ] && [ -n "$ts_current" ] && ! version_gt "$TS_TARGET_VERSION" "$ts_current"; then
    ok "Tailscale is already at $ts_current; use --force to reinstall or downgrade"
    tailscale_ensure_gl_patch
    tailscale_warn_port_forward_conflict
    return 0
  fi
  [ "${GLU_DRY_RUN:-0}" = 1 ] || confirm "Install Tailscale $TS_TARGET_VERSION on $GLU_ROUTER?" || die "cancelled"
  tailscale_download_verified
  info "Copying the verified package to the router"
  remote_open
  remote_push "$TS_PACKAGE" tailscale.tgz
  set -- install-tailscale "$(remote_path tailscale.tgz)" "$TS_SHA256" "$TS_TARGET_VERSION"
  [ "${GLU_DRY_RUN:-0}" = 1 ] && set -- "$@" --dry-run
  [ "${GLU_GL_PATCH:-1}" = 1 ] || set -- "$@" --no-gl-patch
  remote_agent "$@"
  tailscale_warn_port_forward_conflict
}

tailscale_restore() {
  ts_source=${1:-backup}
  confirm "Restore Tailscale from the $ts_source copy on $GLU_ROUTER?" || die "cancelled"
  remote_agent restore-tailscale "$ts_source"
  tailscale_warn_port_forward_conflict
}
