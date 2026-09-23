#!/bin/bash
# Valheim + BepInEx + Modpack installer for Pterodactyl
#
# Server Files: /mnt/server
# Image to install with is 'ghcr.io/ptero-eggs/installers:debian'
apt -y update
apt -y --no-install-recommends --no-install-suggests install curl jq p7zip-full ca-certificates

# Just in case someone removed the defaults.
if [ "${STEAM_USER}" == "" ]; then
    echo -e "steam user is not set.\n"
    echo -e "Using anonymous user.\n"
    STEAM_USER=anonymous
    STEAM_PASS=""
    STEAM_AUTH=""
else
    echo -e "user set to ${STEAM_USER}"
fi

# Download and Install steamcmd
STEAM_TEMP_DIR=$(mktemp -d) || { echo "Failed to create TEMP directory"; exit 1; }
cd "$STEAM_TEMP_DIR"

mkdir -p /mnt/server/steamcmd
curl -fsSL -o steamcmd.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz

if ! 7z x steamcmd.tar.gz -so | 7z x -aoa -si -ttar -o/mnt/server/steamcmd >/dev/null; then
    echo "Error: Failed to extract SteamCMD archive"
    exit 1
fi

mkdir -p /mnt/server/steamapps # Fix steamcmd disk write error when this folder is missing
cd /mnt/server/steamcmd

# SteamCMD fails otherwise for some reason, even running as root.
# This is changed at the end of the install process anyways.
chown -R root:root /mnt
export HOME=/mnt/server

# Install game using SteamCMD
if ! ./steamcmd.sh +force_install_dir /mnt/server +login ${STEAM_USER} ${STEAM_PASS} ${STEAM_AUTH} $( [[ "${WINDOWS_INSTALL}" == "1" ]] && printf %s '+@sSteamCmdForcePlatformType windows' ) +app_update ${SRCDS_APPID} $( [[ -z ${SRCDS_BETAID} ]] || printf %s "-beta ${SRCDS_BETAID}" ) $( [[ -z ${SRCDS_BETAPASS} ]] || printf %s "-betapassword ${SRCDS_BETAPASS}" ) ${INSTALL_FLAGS} validate +quit; then
    echo "Error: SteamCMD failed to install or update the Valheim server"
    exit 1
fi

# Set up 32 bit libraries
mkdir -p /mnt/server/.steam/sdk32
cp -v linux32/steamclient.so ../.steam/sdk32/steamclient.so

# Set up 64 bit libraries
mkdir -p /mnt/server/.steam/sdk64
cp -v linux64/steamclient.so ../.steam/sdk64/steamclient.so

echo "-------------------------------------------------------"
echo "---------Installing BepInEx and Specified Mods---------"
echo "-------------------------------------------------------"

if [ ! -z "$V_MODPACK" ]; then
    echo "Installing modpack: $V_MODPACK"

    # Modpack Name dashes to slashes for URL
    V_MODPACK_CONVERTED=$(echo "$V_MODPACK" | sed 's/-/\//g')
    V_MODPACK_URL="https://hexium.gg/api/experimental/package/${V_MODPACK_CONVERTED}/"

    # Attempt to retrieve ModPack info from Hexium API first. If it fails, fallback to Thunderstore API.
    if ! MODPACK_API_RESPONSE=$(curl -fsSL --max-time 5 -H "accept: application/json" "${V_MODPACK_URL}"); then
        echo "Error: Could not retrieve $V_MODPACK metadata from Hexium API"
        V_MODPACK_URL="https://thunderstore.io/api/experimental/package/${V_MODPACK_CONVERTED}/"

        # Attempt to retrieve ModPack info again, nagainst the Thunderstore API.
        if ! MODPACK_API_RESPONSE=$(curl -fsSL --max-time 5 -H "accept: application/json" "${V_MODPACK_URL}"); then
            echo "Error: Could not retrieve $V_MODPACK metadata from Thunderstore API"
            exit 1
        fi
    fi

    # Extract the version number and download URL from the API response
    BEPINEX_VERSION_NUMBER=$(jq -r '.dependencies[] | select(startswith("denikson-BepInExPack_Valheim-")) | split("-")[-1]' <<< "$MODPACK_API_RESPONSE")
    BEPINEX_DOWNLOAD_URL=$(curl -fsSL --max-time 5 -H "accept: application/json" "${V_MODPACK_URL%%/package/*}/package/denikson/BepInExPack_Valheim/${BEPINEX_VERSION_NUMBER}/" | jq -r ".download_url")
    MODPACK_DEPENDENCIES=$(jq -r '.dependencies[]' <<< "$MODPACK_API_RESPONSE")
else
    echo "No modpack specified, installing latest BepInEx"
    if ! LATEST_BEPINX_API_RESPONSE=$(curl -fsSL --max-time 5 -H "accept: application/json" "https://hexium.gg/api/experimental/package/denikson/BepInExPack_Valheim/"); then
        echo "Error: Could not retrieve BepInEx metadata from Hexium API"

        # Attempt to retrieve BepInEx info again, against the Thunderstore API.
        if ! LATEST_BEPINX_API_RESPONSE=$(curl -fsSL --max-time 5 -H "accept: application/json" "https://thunderstore.io/api/experimental/package/denikson/BepInExPack_Valheim/"); then
            echo "Error: Could not retrieve BepInEx metadata from Thunderstore API"
            exit 1
        fi
    fi
    
    # Extract the version number and download URL from the API response
    BEPINEX_VERSION_NUMBER=$(jq -r  ".latest.version_number" <<< "$LATEST_BEPINX_API_RESPONSE" )
    BEPINEX_DOWNLOAD_URL=$(jq -r  ".latest.download_url" <<< "$LATEST_BEPINX_API_RESPONSE" )
fi

TEMP_DIR=$(mktemp -d) || { echo "Failed to create TEMP directory"; exit 1; }
cd "$TEMP_DIR"

BEPINEX_FILENAME=$(basename "${BEPINEX_DOWNLOAD_URL%%\?*}")

echo "Downloading BepInEx ($BEPINEX_VERSION_NUMBER) from $BEPINEX_DOWNLOAD_URL"
if ! curl -fsS -o "$BEPINEX_FILENAME" "$BEPINEX_DOWNLOAD_URL"; then
    echo "Error: Failed to download BepInEx from $BEPINEX_DOWNLOAD_URL"
    exit 1
fi

if ! 7z x -y "$BEPINEX_FILENAME" >/dev/null; then
    echo "Error: Failed to extract BepInEx from $BEPINEX_FILENAME"
    exit 1
fi

cp -Rf ./BepInExPack_Valheim/* /mnt/server
mkdir -p /mnt/server/BepInEx/plugins
mkdir -p /mnt/server/BepInEx/patchers

echo "BepInEx installation completed."

if [ ! -z "$V_MODPACK_URL" ]; then

    echo "Downloading ModPack ($V_MODPACK) from $V_MODPACK_URL"

    # Delete old dependencies
    rm -Rf /mnt/server/BepInEx/plugins/*
    rm -Rf /mnt/server/BepInEx/patchers/*

    # Download and extract the modpack dlls files
    for MODPACK_DEPENDENCY in $MODPACK_DEPENDENCIES; do
        # Ignore BepInEx
        if [[ "$MODPACK_DEPENDENCY" == *"denikson-BepInExPack_Valheim"* ]]; then
            continue  # Skip this dependency
        fi

        # Dependency Name dashes to slashes for URL
        MODPACK_DEPENDENCY_CONVERTED=$(echo "$MODPACK_DEPENDENCY" | sed 's/-/\//g')
        MODPACK_DEPENDENCY_METADATA_URL="https://hexium.gg/api/experimental/package/${MODPACK_DEPENDENCY_CONVERTED}/"

        # Attempt to retrieve dependency info from Hexium API first. If it fails, fallback to Thunderstore API.
        if ! MODPACK_DEPENDENCY_API_RESPONSE=$(curl -fsSL --max-time 5 -H "accept: application/json" "${MODPACK_DEPENDENCY_METADATA_URL}"); then
            echo "Error: Could not retrieve $MODPACK_DEPENDENCY metadata from Hexium API"
            MODPACK_DEPENDENCY_METADATA_URL="https://thunderstore.io/api/experimental/package/${MODPACK_DEPENDENCY_CONVERTED}/"

            # Attempt to retrieve dependency info again, against the Thunderstore API.
            if ! MODPACK_DEPENDENCY_API_RESPONSE=$(curl -fsSL --max-time 5 -H "accept: application/json" "${MODPACK_DEPENDENCY_METADATA_URL}"); then
                echo "Error: Could not retrieve $MODPACK_DEPENDENCY metadata from Thunderstore API"
                exit 1
            fi
        fi

        # Extract the version number and download URL from the API response
        MODPACK_DEPENDENCY_VERSION_NUMBER=$(jq -r  ".version_number" <<< "$MODPACK_DEPENDENCY_API_RESPONSE" )
        MODPACK_DEPENDENCY_DOWNLOAD_URL=$(jq -r  ".download_url" <<< "$MODPACK_DEPENDENCY_API_RESPONSE" )
        
        # Download dependencies
        echo "Downloading $MODPACK_DEPENDENCY ($MODPACK_DEPENDENCY_VERSION_NUMBER) from $MODPACK_DEPENDENCY_DOWNLOAD_URL"
        
        MODPACK_DEPENDENCY_FILENAME=$(basename "${MODPACK_DEPENDENCY_DOWNLOAD_URL%%\?*}")
        if ! curl -fsSL -o "$MODPACK_DEPENDENCY_FILENAME" "$MODPACK_DEPENDENCY_DOWNLOAD_URL"; then
            echo "Error: Failed to download $MODPACK_DEPENDENCY_DOWNLOAD_URL"
            exit 1
        fi

        # Extract DLL files from the ZIP and delete the zip file
        DEPENDENCY_TEMP_DIR=$(mktemp -d)

        if ! 7z x -y "-o$DEPENDENCY_TEMP_DIR" "$MODPACK_DEPENDENCY_FILENAME" >/dev/null; then
            echo "Error: Failed to extract $MODPACK_DEPENDENCY_FILENAME"
            exit 1
        fi

        # Check if the extracted directory contains BepInEx folder or individual plugin folders
        if [ -d "$DEPENDENCY_TEMP_DIR/BepInEx" ]; then
            echo "Copying BepInEx directory as is"
            cp -Rf "$DEPENDENCY_TEMP_DIR/BepInEx/." /mnt/server/BepInEx
        else
            for MOD_DIRECTORY in plugins patchers; do
                if [ -d "$DEPENDENCY_TEMP_DIR/$MOD_DIRECTORY" ]; then
                    echo "Copying $MOD_DIRECTORY directory into BepInEx directory"
                    cp -Rf "$DEPENDENCY_TEMP_DIR/$MOD_DIRECTORY/." "/mnt/server/BepInEx/$MOD_DIRECTORY"
                fi
            done
        fi

        # Copy root-level DLL files into BepInEx/plugins
        ROOT_DLLS=("$DEPENDENCY_TEMP_DIR"/*.dll)

        if [ -e "${ROOT_DLLS[0]}" ]; then
            cp -f -- "${ROOT_DLLS[@]}" /mnt/server/BepInEx/plugins/
            echo "Copied ROOT level DLL files to BepInEx/plugins"
        fi

        # Clean up temporary files for the current dependency
        rm -Rf "$DEPENDENCY_TEMP_DIR"
        rm -f "$MODPACK_DEPENDENCY_FILENAME"
    done

    echo "All dependencies have been downloaded and installed successfully."
fi

echo "-------------------------------------------------------"
echo "------------------Cleanup TEMP Files-------------------"
echo "-------------------------------------------------------"

# Cleanup leftover files
echo "Cleaning up temporary files..."
rm -Rf "$TEMP_DIR"
rm -Rf "$STEAM_TEMP_DIR"

echo "-------------------------------------------------------"
echo "----------Installation Completed Successfully----------"
echo "-------------------------------------------------------"