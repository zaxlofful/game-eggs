#!/bin/bash
# Valheim + BepInEx + Hexium-first modpack installer for Pterodactyl
#
# Server Files: /mnt/server
# Image to install with is 'ghcr.io/ptero-eggs/installers:debian'
apt -y update
apt -y --no-install-recommends install curl

## just in case someone removed the defaults.
if [ "${STEAM_USER}" == "" ]; then
    echo -e "steam user is not set.\n"
    echo -e "Using anonymous user.\n"
    STEAM_USER=anonymous
    STEAM_PASS=""
    STEAM_AUTH=""
else
    echo -e "user set to ${STEAM_USER}"
fi

## download and install steamcmd
cd /tmp
mkdir -p /mnt/server/steamcmd
curl -sSL -o steamcmd.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
tar -xzvf steamcmd.tar.gz -C /mnt/server/steamcmd
mkdir -p /mnt/server/steamapps # Fix steamcmd disk write error when this folder is missing
cd /mnt/server/steamcmd

# SteamCMD fails otherwise for some reason, even running as root.
# This is changed at the end of the install process anyways.
chown -R root:root /mnt
export HOME=/mnt/server

## install game using steamcmd
./steamcmd.sh +force_install_dir /mnt/server +login ${STEAM_USER} ${STEAM_PASS} ${STEAM_AUTH} $( [[ "${WINDOWS_INSTALL}" == "1" ]] && printf %s '+@sSteamCmdForcePlatformType windows' ) +app_update ${SRCDS_APPID} $( [[ -z ${SRCDS_BETAID} ]] || printf %s "-beta ${SRCDS_BETAID}" ) $( [[ -z ${SRCDS_BETAPASS} ]] || printf %s "-betapassword ${SRCDS_BETAPASS}" ) ${INSTALL_FLAGS} validate +quit ## other flags may be needed depending on install. looking at you cs 1.6

## set up 32 bit libraries
mkdir -p /mnt/server/.steam/sdk32
cp -v linux32/steamclient.so ../.steam/sdk32/steamclient.so

## set up 64 bit libraries
mkdir -p /mnt/server/.steam/sdk64
cp -v linux64/steamclient.so ../.steam/sdk64/steamclient.so

echo "-------------------------------------------------------"
echo "installing BepInEx and Selected ModPacks..."
echo "-------------------------------------------------------"

SERVER_DIR="/mnt/server"
STEAMCMD_DIR="${SERVER_DIR}/steamcmd"

HEXIUM_BASE="https://hexium.gg"
THUNDERSTORE_BASE="https://thunderstore.io"

# Pin BepInEx so reinstalling the same Egg reconstructs the same framework.
BEPINEX_NAMESPACE="denikson"
BEPINEX_NAME="BepInExPack_Valheim"
BEPINEX_VERSION="5.4.2350"

WORK_DIR="$(mktemp -d /tmp/valheim-install.XXXXXX)"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'rc=$?; echo "ERROR: installer failed at line ${LINENO} (exit ${rc})" >&2; exit "$rc"' ERR

fatal() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    printf '%s\n' "$*"
}

# curl flags chosen to work on older Debian installer images too.
CURL_COMMON=(
    --silent
    --show-error
    --location
    --fail
    --retry 5
    --retry-delay 2
    --connect-timeout 15
    --max-time 180
    --proto '=https'
    --proto-redir '=https'
)

apt-get -y update
DEBIAN_FRONTEND=noninteractive apt-get -y \
    --no-install-recommends \
    install ca-certificates curl jq unzip

mkdir -p "$SERVER_DIR"

###############################################################################
# SteamCMD / Valheim
###############################################################################

STEAM_USER="${STEAM_USER:-anonymous}"
STEAM_PASS="${STEAM_PASS:-}"
STEAM_AUTH="${STEAM_AUTH:-}"
SRCDS_APPID="${SRCDS_APPID:-896660}"
EXTRA_FLAGS="${EXTRA_FLAGS:-}"
V_MODPACK="${V_MODPACK:-}"

if [[ "$STEAM_USER" == "anonymous" ]]; then
    log "Steam user not set; using anonymous login."
else
    log "Steam user set to ${STEAM_USER}."
fi

log "-------------------------------------------------------"
log "Installing SteamCMD and Valheim..."
log "-------------------------------------------------------"

mkdir -p "$STEAMCMD_DIR"
curl "${CURL_COMMON[@]}" \
    -o "${WORK_DIR}/steamcmd.tar.gz" \
    "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"

tar -xzf "${WORK_DIR}/steamcmd.tar.gz" -C "$STEAMCMD_DIR"

# Keep ownership change scoped to the server tree rather than all of /mnt.
chown -R root:root "$SERVER_DIR"
export HOME="$SERVER_DIR"

steamcmd_args=(
    +force_install_dir "$SERVER_DIR"
    +login "$STEAM_USER"
)

if [[ "$STEAM_USER" != "anonymous" ]]; then
    if [[ -n "$STEAM_PASS" || -n "$STEAM_AUTH" ]]; then
        steamcmd_args+=("$STEAM_PASS")
    fi
    if [[ -n "$STEAM_AUTH" ]]; then
        steamcmd_args+=("$STEAM_AUTH")
    fi
fi

steamcmd_args+=(+app_update "$SRCDS_APPID")

if [[ -n "$EXTRA_FLAGS" ]]; then
    # Pterodactyl supplies EXTRA_FLAGS as a simple whitespace-separated flag list.
    read -r -a extra_flags <<< "$EXTRA_FLAGS"
    steamcmd_args+=("${extra_flags[@]}")
fi

steamcmd_args+=(+quit)

"${STEAMCMD_DIR}/steamcmd.sh" "${steamcmd_args[@]}"

mkdir -p "${SERVER_DIR}/.steam/sdk32" "${SERVER_DIR}/.steam/sdk64"
cp -f "${STEAMCMD_DIR}/linux32/steamclient.so" "${SERVER_DIR}/.steam/sdk32/steamclient.so"
cp -f "${STEAMCMD_DIR}/linux64/steamclient.so" "${SERVER_DIR}/.steam/sdk64/steamclient.so"

###############################################################################
# Package resolution
###############################################################################

# Globals populated by fetch_package_*.
PACKAGE_JSON=""
PACKAGE_STORE=""

# Resolved dependency graph, keyed by "namespace/name".
declare -A RESOLVED_VERSION=()
declare -A RESOLVED_JSON=()
declare -A RESOLVED_STORE=()
declare -A RESOLVED_ZIP=()
declare -A REACHABLE=()

parse_dependency() {
    local dependency="$1"
    local -n out_namespace="$2"
    local -n out_name="$3"
    local -n out_version="$4"

    local prefix

    # Splitting semver from the right handles prereleases such as 2.0.0-alpha.1.
    if [[ "$dependency" =~ ^(.+)-([0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?)$ ]]; then
        prefix="${BASH_REMATCH[1]}"
        out_version="${BASH_REMATCH[2]}"
    else
        fatal "Invalid dependency string: ${dependency}"
    fi

    if [[ "$prefix" != *-* ]]; then
        fatal "Invalid dependency string: ${dependency}"
    fi

    out_namespace="${prefix%%-*}"
    out_name="${prefix#*-}"

    # Reject path/control characters before values are used in URLs or paths.
    [[ "$out_namespace" =~ ^[A-Za-z0-9_]+$ ]] ||
        fatal "Invalid package namespace in dependency: ${dependency}"
    [[ "$out_name" =~ ^[A-Za-z0-9_]+$ ]] ||
        fatal "Invalid package name in dependency: ${dependency}"
}

parse_semver() {
    local version="$1"
    local -n out_major="$2"
    local -n out_minor="$3"
    local -n out_patch="$4"
    local -n out_rank="$5"
    local -n out_pre_number="$6"

    local prerelease=""

    if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-(alpha|beta|rc)\.([0-9]+))?$ ]]; then
        out_major="${BASH_REMATCH[1]}"
        out_minor="${BASH_REMATCH[2]}"
        out_patch="${BASH_REMATCH[3]}"
        prerelease="${BASH_REMATCH[5]:-}"
        out_pre_number="${BASH_REMATCH[6]:-0}"
    else
        fatal "Unsupported semantic version: ${version}"
    fi

    case "$prerelease" in
        "") out_rank=4 ;;
        rc) out_rank=3 ;;
        beta) out_rank=2 ;;
        alpha) out_rank=1 ;;
        *) out_rank=0 ;;
    esac
}

version_gt() {
    local left="$1"
    local right="$2"
    local lmaj lmin lpat lrank lpre
    local rmaj rmin rpat rrank rpre

    parse_semver "$left" lmaj lmin lpat lrank lpre
    parse_semver "$right" rmaj rmin rpat rrank rpre

    local i a b
    for i in \
        "$((10#$lmaj)):$((10#$rmaj))" \
        "$((10#$lmin)):$((10#$rmin))" \
        "$((10#$lpat)):$((10#$rpat))" \
        "$lrank:$rrank" \
        "$((10#$lpre)):$((10#$rpre))"
    do
        a="${i%%:*}"
        b="${i#*:}"
        (( a > b )) && return 0
        (( a < b )) && return 1
    done

    return 1
}

fetch_package_from_store() {
    local store="$1"
    local namespace="$2"
    local name="$3"
    local version="$4"
    local base url response

    case "$store" in
        hexium) base="$HEXIUM_BASE" ;;
        thunderstore) base="$THUNDERSTORE_BASE" ;;
        *) fatal "Unknown package store: ${store}" ;;
    esac

    url="${base}/api/experimental/package/${namespace}/${name}/${version}/"

    # A lookup failure is expected when falling through to the other repository.
    if ! response="$(curl "${CURL_COMMON[@]}" \
        -H "accept: application/json" \
        "$url" 2>/dev/null)"
    then
        return 1
    fi

    # Exact-version endpoints must provide a usable download URL and dependency array.
    if ! jq -e --arg version "$version" '
        (.download_url | type == "string" and length > 0)
        and ((.dependencies // []) | type == "array")
        and ((.version_number // $version) == $version)
    ' <<< "$response" >/dev/null
    then
        return 1
    fi

    PACKAGE_JSON="$response"
    PACKAGE_STORE="$store"
}

fetch_package_with_fallback() {
    local namespace="$1"
    local name="$2"
    local version="$3"

    fetch_package_from_store hexium "$namespace" "$name" "$version" && return 0
    fetch_package_from_store thunderstore "$namespace" "$name" "$version" && return 0
    return 1
}

resolve_dependency() {
    local dependency="$1"
    local namespace name version key existing dep
    local package_json package_store

    parse_dependency "$dependency" namespace name version

    # BepInEx is installed separately and pinned above.
    if [[ "$namespace" == "$BEPINEX_NAMESPACE" && "$name" == "$BEPINEX_NAME" ]]; then
        if version_gt "$version" "$BEPINEX_VERSION"; then
            fatal "Modpack requires BepInEx ${version}, but installer pins ${BEPINEX_VERSION}"
        fi
        return 0
    fi

    key="${namespace}/${name}"
    existing="${RESOLVED_VERSION[$key]:-}"

    if [[ -n "$existing" ]]; then
        if [[ "$existing" == "$version" ]]; then
            return 0
        fi

        # Dependency strings are minimum-version requirements. Keep the highest
        # minimum encountered, then install that exact version for repeatability.
        if ! version_gt "$version" "$existing"; then
            return 0
        fi

        log "Raising ${namespace}-${name} requirement: ${existing} -> ${version}"
    fi

    log "Resolving ${namespace}-${name}-${version}..."

    if ! fetch_package_with_fallback "$namespace" "$name" "$version"; then
        fatal "Could not resolve ${namespace}-${name}-${version} from Hexium or Thunderstore"
    fi

    package_json="$PACKAGE_JSON"
    package_store="$PACKAGE_STORE"

    RESOLVED_VERSION["$key"]="$version"
    RESOLVED_JSON["$key"]="$package_json"
    RESOLVED_STORE["$key"]="$package_store"

    while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        resolve_dependency "$dep"
    done < <(jq -r '.dependencies[]?' <<< "$package_json")
}

mark_reachable() {
    local dependency="$1"
    local namespace name version key dep

    parse_dependency "$dependency" namespace name version

    if [[ "$namespace" == "$BEPINEX_NAMESPACE" && "$name" == "$BEPINEX_NAME" ]]; then
        return 0
    fi

    key="${namespace}/${name}"

    [[ -n "${RESOLVED_VERSION[$key]:-}" ]] ||
        fatal "Internal resolver error: ${key} was not resolved"

    [[ -z "${REACHABLE[$key]:-}" ]] || return 0
    REACHABLE["$key"]=1

    # Walk dependencies from the final selected version. This drops any stale
    # transitive packages that were only required by a lower version encountered
    # earlier while resolving minimum-version constraints.
    while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        mark_reachable "$dep"
    done < <(jq -r '.dependencies[]?' <<< "${RESOLVED_JSON[$key]}")
}

###############################################################################
# Download validation
###############################################################################

validate_download_url() {
    local store="$1"
    local url="$2"
    local authority host

    [[ "$url" == https://* ]] ||
        fatal "${store} returned a non-HTTPS download URL: ${url}"

    authority="${url#https://}"
    authority="${authority%%/*}"

    [[ "$authority" != *"@"* ]] ||
        fatal "${store} returned a download URL containing credentials"

    host="${authority%%:*}"
    host="${host,,}"

    case "$store" in
        hexium)
            [[ "$host" == "hexium.gg" || "$host" == *".hexium.gg" ]] ||
                fatal "Unexpected Hexium download host: ${host}"
            ;;
        thunderstore)
            [[ "$host" == "thunderstore.io" || "$host" == *".thunderstore.io" ]] ||
                fatal "Unexpected Thunderstore download host: ${host}"
            ;;
        *)
            fatal "Unknown package store: ${store}"
            ;;
    esac
}

validate_zip() {
    local zip_file="$1"

    unzip -tq "$zip_file" >/dev/null ||
        fatal "Archive integrity check failed: ${zip_file}"

    # Reject zip-slip style paths before extraction.
    if unzip -Z1 "$zip_file" | grep -Eq '(^[\\/]|(^|[\\/])\.\.([\\/]|$))'; then
        fatal "Archive contains an unsafe path: ${zip_file}"
    fi
}

download_package_zip() {
    local store="$1"
    local package_json="$2"
    local destination="$3"
    local label="$4"
    local download_url sha256

    download_url="$(jq -er '.download_url' <<< "$package_json")"
    validate_download_url "$store" "$download_url"

    log "Downloading ${label} from ${store}..."
    curl "${CURL_COMMON[@]}" -o "$destination" "$download_url"

    validate_zip "$destination"

    sha256="$(sha256sum "$destination" | awk '{print $1}')"
    log "Validated ${label} (SHA-256 ${sha256})"
}

###############################################################################
# Resolve and stage complete mod set before modifying BepInEx
###############################################################################

MODPACK_JSON=""

if [[ -n "$V_MODPACK" ]]; then
    modpack_namespace=""
    modpack_name=""
    modpack_version=""

    parse_dependency "$V_MODPACK" \
        modpack_namespace modpack_name modpack_version

    log "-------------------------------------------------------"
    log "Resolving modpack ${V_MODPACK}..."
    log "-------------------------------------------------------"

    if ! fetch_package_with_fallback \
        "$modpack_namespace" "$modpack_name" "$modpack_version"
    then
        fatal "Could not resolve modpack ${V_MODPACK} from Hexium or Thunderstore"
    fi

    MODPACK_JSON="$PACKAGE_JSON"
    log "Modpack metadata resolved from ${PACKAGE_STORE}."

    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        resolve_dependency "$dependency"
    done < <(jq -r '.dependencies[]?' <<< "$MODPACK_JSON")

    # Re-walk the graph from the root using only final selected versions.
    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        mark_reachable "$dependency"
    done < <(jq -r '.dependencies[]?' <<< "$MODPACK_JSON")
fi

# BepInEx itself must come from Hexium. Thunderstore is not a bootstrap dependency.
log "Resolving BepInEx ${BEPINEX_VERSION} from Hexium..."
if ! fetch_package_from_store \
    hexium "$BEPINEX_NAMESPACE" "$BEPINEX_NAME" "$BEPINEX_VERSION"
then
    fatal "Could not resolve BepInEx ${BEPINEX_VERSION} from Hexium"
fi
BEPINEX_JSON="$PACKAGE_JSON"
BEPINEX_ZIP="${WORK_DIR}/${BEPINEX_NAMESPACE}-${BEPINEX_NAME}-${BEPINEX_VERSION}.zip"

download_package_zip \
    hexium "$BEPINEX_JSON" "$BEPINEX_ZIP" \
    "${BEPINEX_NAMESPACE}-${BEPINEX_NAME}-${BEPINEX_VERSION}"

if ((${#REACHABLE[@]} > 0)); then
    mapfile -t resolved_keys < <(
        printf '%s\n' "${!REACHABLE[@]}" | LC_ALL=C sort
    )

    for key in "${resolved_keys[@]}"; do
        version="${RESOLVED_VERSION[$key]}"
        package_json="${RESOLVED_JSON[$key]}"
        package_store="${RESOLVED_STORE[$key]}"
        namespace="${key%%/*}"
        name="${key#*/}"
        zip_file="${WORK_DIR}/${namespace}-${name}-${version}.zip"

        download_package_zip \
            "$package_store" "$package_json" "$zip_file" \
            "${namespace}-${name}-${version}"

        RESOLVED_ZIP["$key"]="$zip_file"
    done
fi

###############################################################################
# Installation
###############################################################################

safe_extract_zip() {
    local zip_file="$1"
    local destination="$2"

    rm -rf "$destination"
    mkdir -p "$destination"
    unzip -oq "$zip_file" -d "$destination"

    # Packages do not need symlinks. Reject them so an archive cannot make later
    # copies escape the extraction tree.
    if find "$destination" -type l -print -quit | grep -q .; then
        fatal "Archive contains a symlink: ${zip_file}"
    fi
}

install_bepinex() {
    local extract_dir="${WORK_DIR}/bepinex-extract"
    local source_dir
    local saved_config="${WORK_DIR}/saved-config"

    log "-------------------------------------------------------"
    log "Installing BepInEx ${BEPINEX_VERSION}..."
    log "-------------------------------------------------------"

    # Preserve existing configuration if Pterodactyl has not already wiped it.
    if [[ -d "${SERVER_DIR}/BepInEx/config" ]]; then
        mkdir -p "$saved_config"
        cp -a "${SERVER_DIR}/BepInEx/config/." "$saved_config/"
    fi

    safe_extract_zip "$BEPINEX_ZIP" "$extract_dir"

    if [[ -d "${extract_dir}/BepInExPack_Valheim" ]]; then
        source_dir="${extract_dir}/BepInExPack_Valheim"
    else
        source_dir="$extract_dir"
    fi

    find "$source_dir" -maxdepth 1 -type f \
        \( -iname 'manifest.json' \
        -o -iname 'icon.png' \
        -o -iname 'README*' \
        -o -iname 'CHANGELOG*' \) \
        -delete

    # Clean framework-controlled paths so stale binaries cannot survive reinstall.
    rm -rf \
        "${SERVER_DIR}/BepInEx" \
        "${SERVER_DIR}/doorstop_libs"
    rm -f \
        "${SERVER_DIR}/libdoorstop_x64.so" \
        "${SERVER_DIR}/doorstop_config.ini"

    cp -a "${source_dir}/." "$SERVER_DIR/"

    if [[ -d "$saved_config" ]]; then
        mkdir -p "${SERVER_DIR}/BepInEx/config"
        cp -a "${saved_config}/." "${SERVER_DIR}/BepInEx/config/"
    fi

    mkdir -p \
        "${SERVER_DIR}/BepInEx/plugins" \
        "${SERVER_DIR}/BepInEx/patchers" \
        "${SERVER_DIR}/BepInEx/config" \
        "${SERVER_DIR}/BepInEx/monomod"
}

install_mod_zip() {
    local zip_file="$1"
    local namespace="$2"
    local name="$3"
    local version="$4"

    local package_id="${namespace}-${name}"
    local extract_dir="${WORK_DIR}/extract-${namespace}-${name}-${version}"
    local dir source

    log "Installing ${namespace}-${name}-${version}..."

    safe_extract_zip "$zip_file" "$extract_dir"

    # Some packages wrap their payload in BepInEx/. Normalize that first.
    if [[ -d "${extract_dir}/BepInEx" ]]; then
        cp -a "${extract_dir}/BepInEx/." "$extract_dir/"
        rm -rf "${extract_dir}/BepInEx"
    fi

    # Remove only root-level distribution metadata.
    find "$extract_dir" -maxdepth 1 -type f \
        \( -iname 'manifest.json' \
        -o -iname 'icon.png' \
        -o -iname 'README*' \
        -o -iname 'CHANGELOG*' \) \
        -delete

    # Known BepInEx code directories get isolated per package.
    for dir in plugins patchers core monomod; do
        if [[ -d "${extract_dir}/${dir}" ]]; then
            mkdir -p "${SERVER_DIR}/BepInEx/${dir}/${package_id}"
            cp -a "${extract_dir}/${dir}/." \
                "${SERVER_DIR}/BepInEx/${dir}/${package_id}/"
            rm -rf "${extract_dir:?}/${dir}"
        fi
    done

    # Config files belong directly under BepInEx/config. Existing admin config wins.
    if [[ -d "${extract_dir}/config" ]]; then
        mkdir -p "${SERVER_DIR}/BepInEx/config"
        cp -an "${extract_dir}/config/." "${SERVER_DIR}/BepInEx/config/"
        rm -rf "${extract_dir:?}/config"
    fi

    # MonoMod patches can be shipped at arbitrary depth.
    if find "$extract_dir" -type f -name '*.mm.dll' -print -quit | grep -q .; then
        mkdir -p "${SERVER_DIR}/BepInEx/monomod/${package_id}"
        while IFS= read -r -d '' source; do
            mv "$source" "${SERVER_DIR}/BepInEx/monomod/${package_id}/"
        done < <(find "$extract_dir" -type f -name '*.mm.dll' -print0)
    fi

    # Remaining DLLs are plugins. Keep each package isolated.
    if find "$extract_dir" -type f -name '*.dll' -print -quit | grep -q .; then
        mkdir -p "${SERVER_DIR}/BepInEx/plugins/${package_id}"
        while IFS= read -r -d '' source; do
            mv "$source" "${SERVER_DIR}/BepInEx/plugins/${package_id}/"
        done < <(find "$extract_dir" -type f -name '*.dll' -print0)
    fi

    find "$extract_dir" -type d -empty -delete

    # Any remaining assets/data files stay with the plugin package.
    if [[ -d "$extract_dir" ]] && find "$extract_dir" -mindepth 1 -print -quit | grep -q .; then
        mkdir -p "${SERVER_DIR}/BepInEx/plugins/${package_id}"
        cp -a "${extract_dir}/." "${SERVER_DIR}/BepInEx/plugins/${package_id}/"
    fi

    rm -rf "$extract_dir"
}

install_bepinex

if ((${#REACHABLE[@]} > 0)); then
    mapfile -t resolved_keys < <(
        printf '%s\n' "${!REACHABLE[@]}" | LC_ALL=C sort
    )

    log "-------------------------------------------------------"
    log "Installing ${#resolved_keys[@]} resolved mod package(s)..."
    log "-------------------------------------------------------"

    for key in "${resolved_keys[@]}"; do
        namespace="${key%%/*}"
        name="${key#*/}"
        version="${RESOLVED_VERSION[$key]}"
        zip_file="${RESOLVED_ZIP[$key]}"

        install_mod_zip "$zip_file" "$namespace" "$name" "$version"
    done
fi

echo "-------------------------------------------------------"
echo "cleanup files..."
echo "-------------------------------------------------------"

## Cleanup
rm -fR BepInExPack_Valheim
rm -fR icon.png
rm -fR denikson-BepInExPack_Valheim-*
rm -fR manifest.json
rm -fR README.md

log "-------------------------------------------------------"
log "Installation completed successfully"
log "-------------------------------------------------------"