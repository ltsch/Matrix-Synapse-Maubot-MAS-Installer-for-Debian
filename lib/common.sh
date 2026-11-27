# lib/common.sh - shared helpers for install.sh and upgrade_services.sh
# shellcheck shell=bash
#
# Every component that is not installed from an APT repository is fetched from
# its GitHub release and verified against the SHA-256 digest GitHub publishes
# for the asset (coturn is built from the release's source tarball, which has no
# published digest; its SHA-256 is logged).
#
# Installers keep the previous version next to the new one for a quick rollback:
#   /opt/mas/mas.prev + /opt/mas/share.prev, /usr/local/bin/<binary>.prev,
#   /var/www/<site>.prev  (see docs/ADMIN_GUIDE.md -> Upgrades -> Rollback).
#
# Environment:
#   GITHUB_TOKEN       optional; raises the GitHub API rate limit (60/h unauthenticated)
#   ALLOW_UNVERIFIED=1 install an asset even if GitHub publishes no digest for it

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

CURL_API=(curl -fsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60)
CURL_DL=(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 900)

gh_api() { # gh_api <path> - GitHub REST API GET
    local auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    "${CURL_API[@]}" "${auth[@]}" -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
}

# gh_asset <owner/repo> <asset-name-regex>
# Prints "tag url sha256" for the matching asset of the latest release.
gh_asset() {
    local json
    json=$(gh_api "repos/$1/releases/latest") || return 1
    python3 -I -c '
import json, re, sys
r = json.load(sys.stdin)
for a in r["assets"]:
    if re.fullmatch(sys.argv[1], a["name"]):
        print(r["tag_name"], a["browser_download_url"], (a.get("digest") or "sha256:").split(":", 1)[1])
        break
else:
    sys.exit("no asset matching " + sys.argv[1])
' "$2" <<<"$json"
}

# resolve_asset <owner/repo> <asset-name-regex>  -> sets R_TAG R_URL R_SHA, or dies clearly
resolve_asset() {
    local out
    out=$(gh_asset "$1" "$2") && [ -n "$out" ] \
        || die "could not look up the latest $1 release (network problem or GitHub API rate limit; set GITHUB_TOKEN)"
    read -r R_TAG R_URL R_SHA <<<"$out"
    # shellcheck disable=SC2034  # R_URL/R_SHA are used by callers
    true
}

# fetch_verified <url> <sha256> <outfile>
fetch_verified() {
    "${CURL_DL[@]}" -o "$3" "$1" || die "download failed: $1"
    if [ -n "$2" ]; then
        echo "$2  $3" | sha256sum -c --quiet || die "checksum mismatch for $1"
    elif [ "${ALLOW_UNVERIFIED:-0}" = 1 ]; then
        warn "no digest published for $1; installing UNVERIFIED (ALLOW_UNVERIFIED=1)"
    else
        die "no digest published for $1; refusing to install (set ALLOW_UNVERIFIED=1 to override)"
    fi
}

# latest_coturn_tag - newest non-prerelease X.Y.Z coturn tag (ignores docker/* tags)
latest_coturn_tag() {
    local json
    json=$(gh_api "repos/coturn/coturn/releases?per_page=20") || return 1
    python3 -I -c '
import json, re, sys
print(next(r["tag_name"] for r in json.load(sys.stdin)
           if not r["prerelease"] and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", r["tag_name"])))' <<<"$json"
}

# keep_prev <file> - copy a binary to <file>.prev before it is replaced
keep_prev() { if [ -f "$1" ]; then cp -p "$1" "$1.prev"; fi; }

# swap_dir <new-dir> <live-dir> - replace a directory by rename, keeping <live-dir>.prev
# (the old .prev is only deleted once the new directory is in place)
swap_dir() {
    if [ -d "$2" ]; then rm -rf "$2.old" && mv "$2" "$2.old"; fi
    mv "$1" "$2"
    rm -rf "$2.prev"
    if [ -d "$2.old" ]; then mv "$2.old" "$2.prev"; fi
}

# --- Component installers -----------------------------------------------------
# Each takes a scratch dir, optionally followed by a pre-resolved "tag url sha256"
# (upgrade_services.sh resolves everything up front); otherwise it looks up the latest.

install_mas() {           # Matrix Authentication Service -> /opt/mas/{mas,share}
    local w=$1 tag=${2:-} url=${3:-} sha=${4:-}
    if [ -z "$tag" ]; then resolve_asset element-hq/matrix-authentication-service 'mas-cli-x86_64-linux\.tar\.gz'; tag=$R_TAG url=$R_URL sha=$R_SHA; fi
    log "MAS $tag"
    fetch_verified "$url" "$sha" "$w/mas.tar.gz"
    mkdir -p "$w/mas" /opt/mas && tar xzf "$w/mas.tar.gz" -C "$w/mas"
    rm -rf /opt/mas/share.new && cp -a "$w/mas/share" /opt/mas/share.new
    install -m 755 "$w/mas/mas-cli" /opt/mas/mas.new
    if [ -f /opt/mas/config.yaml ]; then   # validate existing config before swapping in
        (cd /opt/mas && sudo -u mas MAS_CONFIG=/opt/mas/config.yaml /opt/mas/mas.new config check) \
            || { rm -rf /opt/mas/share.new /opt/mas/mas.new; die "existing MAS config fails validation with $tag; nothing changed"; }
    fi
    keep_prev /opt/mas/mas
    swap_dir /opt/mas/share.new /opt/mas/share
    mv /opt/mas/mas.new /opt/mas/mas
    echo "$tag"
}

# _install_site <tarball-top-dir> <live-dir> <config files to carry over...>
_install_site() {
    local src=$1 live=$2 f; shift 2
    rm -rf "$live.new" && cp -a "$src" "$live.new"
    for f in "$@"; do
        if [ -f "$live/$f" ]; then mkdir -p "$(dirname "$live.new/$f")" && cp -p "$live/$f" "$live.new/$f"; fi
    done
    chown -R www-data:www-data "$live.new"
    swap_dir "$live.new" "$live"
}

install_element_web() {   # Element Web -> /var/www/element-web (configs preserved)
    local w=$1 tag=${2:-} url=${3:-} sha=${4:-}
    if [ -z "$tag" ]; then resolve_asset element-hq/element-web 'element-v[0-9.]+\.tar\.gz'; tag=$R_TAG url=$R_URL sha=$R_SHA; fi
    log "Element Web $tag"
    fetch_verified "$url" "$sha" "$w/element.tar.gz"
    tar xzf "$w/element.tar.gz" -C "$w"
    _install_site "$w/element-$tag" /var/www/element-web config.json widgets/element-call/config.json
}

install_synapse_admin() { # Synapse-Admin -> /var/www/synapse-admin (config preserved)
    local w=$1 tag=${2:-} url=${3:-} sha=${4:-}
    if [ -z "$tag" ]; then resolve_asset Awesome-Technologies/synapse-admin 'synapse-admin-[0-9.]+\.tar\.gz'; tag=$R_TAG url=$R_URL sha=$R_SHA; fi
    log "Synapse-Admin $tag"
    fetch_verified "$url" "$sha" "$w/sa.tar.gz"
    tar xzf "$w/sa.tar.gz" -C "$w"
    echo "$tag" > "$w/synapse-admin-$tag/.version"
    _install_site "$w/synapse-admin-$tag" /var/www/synapse-admin config.json
}

install_livekit() {       # LiveKit SFU -> /usr/local/bin/livekit-server
    local w=$1 tag=${2:-} url=${3:-} sha=${4:-}
    if [ -z "$tag" ]; then resolve_asset livekit/livekit 'livekit_[0-9.]+_linux_amd64\.tar\.gz'; tag=$R_TAG url=$R_URL sha=$R_SHA; fi
    log "LiveKit $tag"
    fetch_verified "$url" "$sha" "$w/livekit.tar.gz"
    mkdir -p "$w/lk" && tar xzf "$w/livekit.tar.gz" -C "$w/lk"
    keep_prev /usr/local/bin/livekit-server
    install -m 755 "$w/lk/livekit-server" /usr/local/bin/livekit-server
}

install_lk_jwt() {        # MatrixRTC Authorization Service -> /usr/local/bin/lk-jwt-service
    local w=$1 tag=${2:-} url=${3:-} sha=${4:-}
    if [ -z "$tag" ]; then resolve_asset element-hq/lk-jwt-service 'lk-jwt-service_linux_amd64'; tag=$R_TAG url=$R_URL sha=$R_SHA; fi
    log "lk-jwt-service $tag"
    fetch_verified "$url" "$sha" "$w/lk-jwt-service"
    keep_prev /usr/local/bin/lk-jwt-service
    install -m 755 "$w/lk-jwt-service" /usr/local/bin/lk-jwt-service
    mkdir -p /usr/local/lib && echo "$tag" > /usr/local/lib/lk-jwt-service.version
}

build_coturn() {          # coturn <tag> from source -> /usr/local/bin (needs build deps)
    local w=$1 tag=$2 f
    log "coturn $tag (building from source)"
    "${CURL_DL[@]}" -o "$w/coturn.tar.gz" "https://github.com/coturn/coturn/archive/refs/tags/$tag.tar.gz" \
        || die "download of coturn $tag failed"
    log "  source sha256 $(sha256sum "$w/coturn.tar.gz" | cut -d' ' -f1)"
    tar xzf "$w/coturn.tar.gz" -C "$w"
    (cd "$w/coturn-$tag" && ./configure --prefix=/usr/local --turndbdir=/var/lib/turn >/dev/null && make -j"$(nproc)" >/dev/null) \
        || die "coturn $tag failed to build; the installed version is unchanged"
    keep_prev /usr/local/bin/turnserver
    for f in turnserver turnadmin turnutils_uclient turnutils_stunclient turnutils_peer \
             turnutils_natdiscovery turnutils_oauth turnutils_rfc5769check; do
        if [ -e "$w/coturn-$tag/bin/$f" ]; then install -m 755 "$w/coturn-$tag/bin/$f" "/usr/local/bin/$f"; fi
    done
}
