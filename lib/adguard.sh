AGH_REPO=AdguardTeam/AdGuardHome
AGH_API_URL="https://api.github.com/repos/$AGH_REPO/releases/latest"
AGH_DOWNLOAD_URL="https://github.com/$AGH_REPO/releases/download"

adguard_resolve_target() {
  remote_facts
  agh_arch=$(fact arch.adguard)
  [ -n "$agh_arch" ] || die "the router reported no AdGuard Home architecture"
  if [ -n "${GLU_TARGET_VERSION:-}" ]; then
    AGH_TARGET_TAG="v$(normalize_version "$GLU_TARGET_VERSION")"
  else
    agh_release="$GLU_WORKDIR/adguard-release.json"
    fetch_to "$AGH_API_URL" "$agh_release"
    AGH_TARGET_TAG=$(json_value "$agh_release" tag_name) || die "cannot read the AdGuard Home release"
  fi
  AGH_TARGET_VERSION=$(normalize_version "$AGH_TARGET_TAG")
  AGH_ARCHIVE="AdGuardHome_${agh_arch}.tar.gz"
}

adguard_download_verified() {
  agh_dir="$GLU_WORKDIR/adguard"
  mkdir -p "$agh_dir"
  info "Downloading $AGH_ARCHIVE $AGH_TARGET_TAG from github.com/$AGH_REPO"
  fetch_to "$AGH_DOWNLOAD_URL/$AGH_TARGET_TAG/$AGH_ARCHIVE" "$agh_dir/$AGH_ARCHIVE" "$FETCH_MAX_PACKAGE_BYTES"
  fetch_to "$AGH_DOWNLOAD_URL/$AGH_TARGET_TAG/checksums.txt" "$agh_dir/checksums.txt"

  agh_expected=$(awk -v name="$AGH_ARCHIVE" '$2 == name || $2 == "./" name { print $1; exit }' "$agh_dir/checksums.txt")
  [ -n "$agh_expected" ] || die "checksums.txt has no entry for $AGH_ARCHIVE"
  AGH_SHA256=$(sha256_of "$agh_dir/$AGH_ARCHIVE")
  [ "$AGH_SHA256" = "$agh_expected" ] || die "AdGuard Home checksum does NOT match the release checksums; nothing was installed"
  ok "sha256 $AGH_SHA256 matches the release checksums"
  AGH_PACKAGE="$agh_dir/$AGH_ARCHIVE"
}

adguard_update() {
  remote_facts
  agh_current=$(fact adguard.version)
  adguard_resolve_target
  info "AdGuard Home on router: ${agh_current:-not installed}, target: $AGH_TARGET_VERSION"
  if [ "${GLU_FORCE:-0}" != 1 ] && [ -n "$agh_current" ] && ! version_gt "$AGH_TARGET_VERSION" "$agh_current"; then
    ok "AdGuard Home is already at $agh_current; use --force to reinstall or downgrade"
    return 0
  fi
  [ "${GLU_DRY_RUN:-0}" = 1 ] || confirm "Install AdGuard Home $AGH_TARGET_VERSION on $GLU_ROUTER?" || die "cancelled"
  adguard_download_verified
  info "Copying the verified package to the router"
  remote_open
  remote_push "$AGH_PACKAGE" adguard.tar.gz
  set -- install-adguard "$(remote_path adguard.tar.gz)" "$AGH_SHA256" "$AGH_TARGET_VERSION"
  [ "${GLU_DRY_RUN:-0}" = 1 ] && set -- "$@" --dry-run
  remote_agent "$@"
}

adguard_restore() {
  agh_source=${1:-backup}
  confirm "Restore AdGuard Home from the $agh_source copy on $GLU_ROUTER?" || die "cancelled"
  remote_agent restore-adguard "$agh_source"
}
