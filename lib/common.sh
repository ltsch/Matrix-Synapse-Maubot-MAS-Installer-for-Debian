# lib/common.sh - shared helpers for install.sh and upgrade_services.sh
# shellcheck shell=bash
#
# Every component that is not installed from an APT repository is fetched from
# its GitHub release and verified against the SHA-256 digest GitHub publishes
# for the asset (coturn is built from the release's source tarball).

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# gh_asset <owner/repo> <asset-name-regex>
# Prints "tag url sha256" for the matching asset of the latest release.
gh_asset() {
    curl -fsS "https://api.github.com/repos/$1/releases/latest" | python3 -I -c '
import json, re, sys
r = json.load(sys.stdin)
for a in r["assets"]:
    if re.fullmatch(sys.argv[1], a["name"]):
        print(r["tag_name"], a["browser_download_url"], (a.get("digest") or "sha256:").split(":", 1)[1])
        break
else:
    sys.exit("no asset matching " + sys.argv[1])
' "$2"
}

# fetch_verified <url> <sha256> <outfile>
fetch_verified() {
    curl -fsSL -o "$3" "$1"
    if [ -n "$2" ]; then
        echo "$2  $3" | sha256sum -c --quiet || die "checksum mismatch for $1"
    else
        warn "no digest published for $1, skipping checksum verification"
    fi
}

# latest_coturn_tag - newest non-prerelease X.Y.Z coturn tag (ignores docker/* tags)
latest_coturn_tag() {
    curl -fsS "https://api.github.com/repos/coturn/coturn/releases?per_page=20" | python3 -I -c '
import json, re, sys
print(next(r["tag_name"] for r in json.load(sys.stdin)
           if not r["prerelease"] and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", r["tag_name"])))'
}

# --- Component installers (all take a scratch dir as $1) --------------------

install_mas() {           # Matrix Authentication Service -> /opt/mas/{mas,share}
    local w=$1 tag url sha
    read -r tag url sha < <(gh_asset element-hq/matrix-authentication-service 'mas-cli-x86_64-linux\.tar\.gz')
    log "MAS $tag"
    fetch_verified "$url" "$sha" "$w/mas.tar.gz"
    mkdir -p "$w/mas" /opt/mas && tar xzf "$w/mas.tar.gz" -C "$w/mas"
    rm -rf /opt/mas/share.new && cp -a "$w/mas/share" /opt/mas/share.new
    install -m 755 "$w/mas/mas-cli" /opt/mas/mas.new
    if [ -f /opt/mas/config.yaml ]; then   # validate existing config before swapping in
        (cd /opt/mas && sudo -u mas MAS_CONFIG=/opt/mas/config.yaml /opt/mas/mas.new config check) \
            || die "existing MAS config fails validation with $tag"
    fi
    rm -rf /opt/mas/share.old; [ -d /opt/mas/share ] && mv /opt/mas/share /opt/mas/share.old
    mv /opt/mas/share.new /opt/mas/share && mv /opt/mas/mas.new /opt/mas/mas
    rm -rf /opt/mas/share.old
    echo "$tag"
}

install_element_web() {   # Element Web -> /var/www/element-web (configs preserved)
    local w=$1 tag url sha
    read -r tag url sha < <(gh_asset element-hq/element-web 'element-v[0-9.]+\.tar\.gz')
    log "Element Web $tag"
    fetch_verified "$url" "$sha" "$w/element.tar.gz"
    tar xzf "$w/element.tar.gz" -C "$w"
    mkdir -p /var/www/element-web
    [ -f /var/www/element-web/config.json ] && cp /var/www/element-web/config.json "$w/ew-config.json"
    [ -f /var/www/element-web/widgets/element-call/config.json ] && cp /var/www/element-web/widgets/element-call/config.json "$w/ec-config.json"
    rm -rf /var/www/element-web/*
    cp -r "$w/element-$tag"/* /var/www/element-web/
    if [ -f "$w/ew-config.json" ]; then cp "$w/ew-config.json" /var/www/element-web/config.json; fi
    if [ -f "$w/ec-config.json" ]; then cp "$w/ec-config.json" /var/www/element-web/widgets/element-call/config.json; fi
    chown -R www-data:www-data /var/www/element-web
}

install_synapse_admin() { # Synapse-Admin -> /var/www/synapse-admin (config preserved)
    local w=$1 tag url sha
    read -r tag url sha < <(gh_asset Awesome-Technologies/synapse-admin 'synapse-admin-[0-9.]+\.tar\.gz')
    log "Synapse-Admin $tag"
    fetch_verified "$url" "$sha" "$w/sa.tar.gz"
    tar xzf "$w/sa.tar.gz" -C "$w"
    mkdir -p /var/www/synapse-admin
    [ -f /var/www/synapse-admin/config.json ] && cp /var/www/synapse-admin/config.json "$w/sa-config.json"
    rm -rf /var/www/synapse-admin/*
    cp -r "$w/synapse-admin-$tag"/* /var/www/synapse-admin/
    if [ -f "$w/sa-config.json" ]; then cp "$w/sa-config.json" /var/www/synapse-admin/config.json; fi
    echo "$tag" > /var/www/synapse-admin/.version
    chown -R www-data:www-data /var/www/synapse-admin
}

install_livekit() {       # LiveKit SFU -> /usr/local/bin/livekit-server
    local w=$1 tag url sha
    read -r tag url sha < <(gh_asset livekit/livekit 'livekit_[0-9.]+_linux_amd64\.tar\.gz')
    log "LiveKit $tag"
    fetch_verified "$url" "$sha" "$w/livekit.tar.gz"
    mkdir -p "$w/lk" && tar xzf "$w/livekit.tar.gz" -C "$w/lk"
    install -m 755 "$w/lk/livekit-server" /usr/local/bin/livekit-server
}

install_lk_jwt() {        # MatrixRTC Authorization Service -> /usr/local/bin/lk-jwt-service
    local w=$1 tag url sha
    read -r tag url sha < <(gh_asset element-hq/lk-jwt-service 'lk-jwt-service_linux_amd64')
    log "lk-jwt-service $tag"
    fetch_verified "$url" "$sha" "$w/lk-jwt-service"
    install -m 755 "$w/lk-jwt-service" /usr/local/bin/lk-jwt-service
    mkdir -p /usr/local/lib && echo "$tag" > /usr/local/lib/lk-jwt-service.version
}

build_coturn() {          # coturn <tag> from source -> /usr/local/bin (needs build deps)
    local w=$1 tag=$2 f
    log "coturn $tag (building from source)"
    curl -fsSL -o "$w/coturn.tar.gz" "https://github.com/coturn/coturn/archive/refs/tags/$tag.tar.gz"
    tar xzf "$w/coturn.tar.gz" -C "$w"
    (cd "$w/coturn-$tag" && ./configure --prefix=/usr/local --turndbdir=/var/lib/turn >/dev/null && make -j"$(nproc)" >/dev/null)
    for f in turnserver turnadmin turnutils_uclient turnutils_stunclient turnutils_peer \
             turnutils_natdiscovery turnutils_oauth turnutils_rfc5769check; do
        if [ -e "$w/coturn-$tag/bin/$f" ]; then install -m 755 "$w/coturn-$tag/bin/$f" "/usr/local/bin/$f"; fi
    done
}
