#!/bin/bash
# Valheim + BepInEx + Hexium-first modpack installer for Pterodactyl
#
# Server Files: /mnt/server
# Image to install with is 'ghcr.io/ptero-eggs/installers:debian'
apt -y update
apt -y --no-install-recommends --no-install-suggests install curl jq unzip tar ca-certificates

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
echo "---------Installing BepInEx and Specified Mods---------"
echo "-------------------------------------------------------"

if [ ! -z "$V_MODPACK" ]; then

    # Modpack Name dashes to slashes for URL
    V_MODPACK_CONVERTED=$(echo "$V_MODPACK" | sed 's/-/\//g')
    V_MODPACK_URL="https://hexium.gg/api/experimental/package/${V_MODPACK_CONVERTED}/"

    # Attempt to retrieve ModPack info from Hexium API first. If it fails, fallback to Thunderstore API.
    if ! MODPACK_API_RESPONSE=$(curl -sfSL -H "accept: application/json" "${V_MODPACK_URL}"); then
        echo "Error: Could not retrieve ModPack info from Hexium API"
        V_MODPACK_URL="https://thunderstore.io/api/experimental/package/${V_MODPACK_CONVERTED}/"

        # Attempt to retrieve ModPack info again, nagainst the Thunderstore API.
        if ! MODPACK_API_RESPONSE=$(curl -sfSL -H "accept: application/json" "${V_MODPACK_URL}"); then
            echo "Error: Could not retrieve ModPack info from Hexium or Thunderstore API"
            exit 1
        fi
    fi

    BEPINEX_VERSION_NUMBER=$(jq -r '.dependencies[] | select(startswith("denikson-BepInExPack_Valheim-")) | split("-")[-1]' <<< "$MODPACK_API_RESPONSE")
    BEPINEX_DOWNLOAD_URL="${V_MODPACK_URL%%/package/*}/package/denikson/BepInExPack_Valheim/${BEPINEX_VERSION_NUMBER}/"
    MODPACK_DEPENDENCIES=$(jq -r '.dependencies[]' <<< "$MODPACK_API_RESPONSE")
else
    if ! LATEST_BEPINX_API_RESPONSE=$(curl -sfSL -H "accept: application/json" "https://hexium.gg/api/experimental/package/denikson/BepInExPack_Valheim/"); then
        echo "Error: Could not retrieve BepInEx info from Hexium API"

        # Attempt to retrieve BepInEx info again, against the Thunderstore API.
        if ! LATEST_BEPINX_API_RESPONSE=$(curl -sfSL -H "accept: application/json" "https://thunderstore.io/api/experimental/package/denikson/BepInExPack_Valheim/"); then
            echo "Error: Could not retrieve BepInEx info from Hexium or Thunderstore API"
            exit 1
        fi
    fi
    
    BEPINEX_VERSION_NUMBER=$(jq -r  ".latest.version_number" <<< "$LATEST_BEPINX_API_RESPONSE" )
    BEPINEX_DOWNLOAD_URL=$(jq -r  ".latest.download_url" <<< "$LATEST_BEPINX_API_RESPONSE" )
fi

cd /mnt/server
echo "Downloading BepInEx: $BEPINEX_DOWNLOAD_URL"
curl -OJ $BEPINEX_DOWNLOAD_URL | unzip -o
cp -r /mnt/server/BepInExPack_Valheim/* /mnt/server

if [ ! -z "$V_MODPACK_URL" ]; then

    echo "Downloading ModPack: $V_MODPACK_URL"

    #Delete Old Mods
    rm -rf /mnt/server/BepInEx/plugins/*

    #Download and extract the modpack dlls files
    for MODPACK_DEPENDENCY in $MODPACK_DEPENDENCIES; do
        #ignore bepinex
        if [[ "$MODPACK_DEPENDENCY" == *"denikson-BepInExPack_Valheim"* ]]; then
            continue  # Skip this dependency
        fi

        # Dependency Name dashes to slashes for URL
        MODPACK_DEPENDENCY_CONVERTED=$(echo "$MODPACK_DEPENDENCY" | sed 's/-/\//g')
        MODPACK_DEPENDENCY_URL="https://hexium.gg/api/experimental/package/${MODPACK_DEPENDENCY_CONVERTED}/"

        # Attempt to retrieve dependency info from Hexium API first. If it fails, fallback to Thunderstore API.
        if ! MODPACK_DEPENDENCY_API_RESPONSE=$(curl -sfSL -H "accept: application/json" "${MODPACK_DEPENDENCY_URL}"); then
            echo "Error: Could not retrieve dependency info from Hexium API"
            MODPACK_DEPENDENCY_URL="https://thunderstore.io/api/experimental/package/${MODPACK_DEPENDENCY_CONVERTED}/"

            # Attempt to retrieve dependency info again, against the Thunderstore API.
            if ! MODPACK_DEPENDENCY_API_RESPONSE=$(curl -sfSL -H "accept: application/json" "${MODPACK_DEPENDENCY_URL}"); then
                echo "Error: Could not retrieve dependency info from Hexium or Thunderstore API"
                exit 1
            fi
        fi
        
        # Download dependencies
        curl -OJ "$MODPACK_DEPENDENCY_URL"

        # Extract DLL files from the ZIP and delete the zip file
        TEMP_DIR=$(mktemp -d)

        unzip -q "$MODPACK_DEPENDENCY.zip" -d "$TEMP_DIR"

        # Check if the extracted directory contains BepInEx folder or individual plugin folders
        if [ -d "$TEMP_DIR/BepInEx" ]; then
            cp -R "$TEMP_DIR/BepInEx/"* /mnt/server/BepInEx/
        else
            for directory in plugins patchers config core; do
                if [ -d "$TEMP_DIR/$directory" ]; then
                    mkdir -p "/mnt/server/BepInEx/$directory"
                    cp -R "$TEMP_DIR/$directory/"* "/mnt/server/BepInEx/$directory/"
                fi
            done
        fi

        rm -Rf "$TEMP_DIR"
        rm -f "$MODPACK_DEPENDENCY.zip"
    done
fi

echo "-------------------------------------------------------"
echo "---------------------Cleanup Files---------------------"
echo "-------------------------------------------------------"

## Cleanup
rm -Rf BepInExPack_Valheim
rm -f icon.png
rm -Rf denikson-BepInExPack_Valheim-*
rm -f manifest.json
rm -f README.md

log "-------------------------------------------------------"
log "Installation completed successfully"
log "-------------------------------------------------------"