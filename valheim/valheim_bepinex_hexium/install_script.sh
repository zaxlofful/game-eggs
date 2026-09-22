#!/bin/bash
# Valheim Installation Script
#
# Server Files: /mnt/server
# Image to install with is 'debian:buster-slim'
apt -y update
apt -y --no-install-recommends --no-install-suggests install wget

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
cd /mnt/server/steamcmd

# SteamCMD fails otherwise for some reason, even running as root.
# This is changed at the end of the install process anyways.
chown -R root:root /mnt
export HOME=/mnt/server

## install game using steamcmd
./steamcmd.sh +force_install_dir /mnt/server +login ${STEAM_USER} ${STEAM_PASS} ${STEAM_AUTH} +app_update ${SRCDS_APPID} ${EXTRA_FLAGS} +quit

## set up 32 bit libraries
mkdir -p /mnt/server/.steam/sdk32
cp -v linux32/steamclient.so ../.steam/sdk32/steamclient.so

## set up 64 bit libraries
mkdir -p /mnt/server/.steam/sdk64
cp -v linux64/steamclient.so ../.steam/sdk64/steamclient.so

fatal() {
  echo "$1" >&2
  exit 1
}

# Both stores expose a Thunderstore-compatible "experimental package" API, so the
# same lookup logic works for either one, just pointed at a different base URL.
THUNDERSTORE_BASE="https://thunderstore.io"
HEXIUM_BASE="https://valheim.hexium.gg"

# namespace-name-version has a variable number of dashes, so split from the ends:
# version is everything after the last dash, namespace is everything before the first.
parse_dependency() {
  local dependency="$1"
  DEP_VERSION="${dependency##*-}"
  local remainder="${dependency%-*}"
  DEP_NAMESPACE="${remainder%%-*}"
  DEP_NAME="${remainder#*-}"
}

# Extracts a downloaded mod zip into the correct BepInEx subfolder instead of
# dumping every DLL into BepInEx/plugins regardless of what the mod actually is.
install_mod_zip() {
  local zip_file="$1"
  local full_name="$2"
  local extract_dir="/tmp/extract_${full_name}"

  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  unzip -oq "$zip_file" -d "$extract_dir"

  # Strip metadata files that aren't part of the mod itself.
  find "$extract_dir" -maxdepth 1 \( -iname "manifest.json" -o -iname "README.md" -o -iname "icon.png" \) -exec rm -f {} +

  if [ -d "$extract_dir/BepInEx" ]; then
    # Zip already mirrors the full BepInEx folder layout (plugins/config/patchers/core).
    cp -r "$extract_dir/BepInEx/." /mnt/server/BepInEx/
  elif [ -d "$extract_dir/plugins" ] || [ -d "$extract_dir/patchers" ] || [ -d "$extract_dir/config" ] || [ -d "$extract_dir/core" ]; then
    # Zip root already uses BepInEx subfolder names, merge them in directly.
    for sub in plugins patchers config core; do
      if [ -d "$extract_dir/$sub" ]; then
        mkdir -p "/mnt/server/BepInEx/$sub"
        cp -r "$extract_dir/$sub/." "/mnt/server/BepInEx/$sub/"
      fi
    done
  else
    # No known layout, keep the mod's own files together in their own plugin folder.
    mkdir -p "/mnt/server/BepInEx/plugins/${full_name}"
    cp -r "$extract_dir/." "/mnt/server/BepInEx/plugins/${full_name}/"
  fi

  rm -rf "$extract_dir"
}

# Downloads a single dependency from the given store and installs it.
install_dependency() {
  local store_base="$1"
  local dependency="$2"

  parse_dependency "$dependency"

  if ! dep_response=$(curl -sfSL -H "accept: application/json" "${store_base}/api/experimental/package/${DEP_NAMESPACE}/${DEP_NAME}/"); then
    echo "Warning: could not retrieve info for ${dependency} from ${store_base}, skipping." >&2
    return
  fi

  local dep_download_url
  dep_download_url=$(jq -r '.latest.download_url' <<< "$dep_response")
  if [ -z "$dep_download_url" ] || [ "$dep_download_url" == "null" ]; then
    echo "Warning: no download URL for ${dependency} from ${store_base}, skipping." >&2
    return
  fi

  local zip_file="/tmp/${dependency}.zip"
  wget -q -O "$zip_file" "$dep_download_url"
  install_mod_zip "$zip_file" "$dependency"
  rm -f "$zip_file"
}

echo "-------------------------------------------------------"
echo "installing BepInEx and Selected ModPacks..."
echo "-------------------------------------------------------"
if ! api_response=$(curl -sfSL -H "accept: application/json" "${THUNDERSTORE_BASE}/api/experimental/package/denikson/BepInExPack_Valheim/"); then
        fatal "Error: could not retrieve BepInEx release info from Thunderstore.io API"
fi

download_url=$(jq -r  ".latest.download_url" <<< "$api_response" )
version_number=$(jq -r  ".latest.version_number" <<< "$api_response" )

V_MODPACK_DEPENDENCIES=""
V_HEXIUM_MODPACK_DEPENDENCIES=""

if [ ! -z "$V_MODPACK" ]
then
#Modpack Name dashes to slashes for URL
V_MODPACK_URL=$(echo "$V_MODPACK" | sed 's/-/\//g')

#Extract dependencies from ModPack JSON data
V_MODPACK_DEPENDENCIES=$(curl -sfSL -H "accept: application/json" "${THUNDERSTORE_BASE}/api/experimental/package/${V_MODPACK_URL}" | jq -r '.dependencies[]')
fi

if [ ! -z "$V_HEXIUM_MODPACK" ]
then
#Modpack Name dashes to slashes for URL
V_HEXIUM_MODPACK_URL=$(echo "$V_HEXIUM_MODPACK" | sed 's/-/\//g')

#Extract dependencies from ModPack JSON data
V_HEXIUM_MODPACK_DEPENDENCIES=$(curl -sfSL -H "accept: application/json" "${HEXIUM_BASE}/api/experimental/package/${V_HEXIUM_MODPACK_URL}" | jq -r '.dependencies[]')
fi

cd /mnt/server
#echo $download_url
wget --content-disposition $download_url
unzip -o denikson-BepInExPack_Valheim-${version_number}.zip
cp -r /mnt/server/BepInExPack_Valheim/* /mnt/server

if [ ! -z "$V_MODPACK_DEPENDENCIES" ] || [ ! -z "$V_HEXIUM_MODPACK_DEPENDENCIES" ]
then
#Delete Old Mods
rm -rf /mnt/server/BepInEx/plugins/*

#Download and install the Thunderstore modpack's dependencies
for V_MODPACK_DEPENDENCY in $V_MODPACK_DEPENDENCIES; do
  #ignore bepinex, it's already installed above
  if [[ "$V_MODPACK_DEPENDENCY" == *"denikson-BepInExPack_Valheim"* ]]; then
    continue  # Skip this dependency
  fi

  install_dependency "$THUNDERSTORE_BASE" "$V_MODPACK_DEPENDENCY"
done

#Download and install the Hexium modpack's dependencies
for V_HEXIUM_MODPACK_DEPENDENCY in $V_HEXIUM_MODPACK_DEPENDENCIES; do
  #ignore bepinex, it's already installed above
  if [[ "$V_HEXIUM_MODPACK_DEPENDENCY" == *"denikson-BepInExPack_Valheim"* ]]; then
    continue  # Skip this dependency
  fi

  install_dependency "$HEXIUM_BASE" "$V_HEXIUM_MODPACK_DEPENDENCY"
done
fi

##cleanup
echo "-------------------------------------------------------"
echo "cleanup files..."
echo "-------------------------------------------------------"
rm -fR BepInExPack_Valheim
rm -fR icon.png
rm -fR denikson-BepInExPack_Valheim-*
rm -fR manifest.json
rm -fR README.m

#rm -fR start_*

echo "-------------------------------------------------------"
echo "Installation completed"
echo "-------------------------------------------------------"