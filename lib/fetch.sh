FETCH_MAX_PACKAGE_BYTES=209715200
FETCH_MAX_SMALL_BYTES=1048576

fetch_to() {
  fetch_url=$1
  fetch_out=$2
  fetch_limit=${3:-$FETCH_MAX_SMALL_BYTES}
  case $fetch_url in
    https://*) ;;
    *) die "refusing to download over plain HTTP: $fetch_url" ;;
  esac
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 900 \
    --max-filesize "$fetch_limit" \
    --user-agent "glinet-updater/$GLU_VERSION" \
    --output "$fetch_out" "$fetch_url" || die "download failed: $fetch_url"
  fetch_size=$(wc -c <"$fetch_out" | tr -d ' ')
  [ "$fetch_size" -gt 0 ] || die "empty download: $fetch_url"
  [ "$fetch_size" -le "$fetch_limit" ] || die "download is larger than $fetch_limit bytes: $fetch_url"
}
