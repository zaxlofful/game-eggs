#!/bin/bash
# Valheim + BepInEx + Modpack installer for Pterodactyl
#
# Server Files: /mnt/server
# Image to install with is 'ghcr.io/ptero-eggs/installers:debian'

clear
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}-------------------------------------------------------${NC}"
echo -e "${YELLOW}-----Install Valheim Dedicated Server via SteamCMD-----${NC}"
echo -e "${BLUE}-------------------------------------------------------${NC}"

echo -e "${YELLOW}Updating package lists and installing required system dependencies...${NC}"
apt -y update
apt -y --no-install-recommends --no-install-suggests install curl jq p7zip-full ca-certificates

# Just in case someone removed the defaults.
if [ "${STEAM_USER}" == "" ]; then
    echo -e "${YELLOW}steam user is not set.${NC}\n"
    echo -e "${YELLOW}Using anonymous user.${NC}\n"
    STEAM_USER=anonymous
    STEAM_PASS=""
    STEAM_AUTH=""
else
    echo -e "${YELLOW}user set to ${STEAM_USER}${NC}"
fi

STEAM_TEMP_DIR=$(mktemp -d) || { echo "Failed to create TEMP directory"; exit 1; }
cd "$STEAM_TEMP_DIR"

# Download and Install steamcmd
echo -e "${YELLOW}Downloading Compressed Linux SteamCMD...${NC}"
if ! curl -fsSL -o steamcmd.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz; then
    echo -e "${RED}Error: Failed to download SteamCMD from https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz${NC}"
    exit 1
fi

mkdir -p /mnt/server/steamcmd

echo -e "${YELLOW}Decompressing Linux SteamCMD...${NC}"
if ! 7z x steamcmd.tar.gz -so | 7z x -aoa -si -ttar -o/mnt/server/steamcmd >/dev/null; then
    echo -e "${RED}Error: Failed to extract SteamCMD archive${NC}"
    exit 1
fi

mkdir -p /mnt/server/steamapps # Fix steamcmd disk write error when this folder is missing
cd /mnt/server/steamcmd

# SteamCMD fails otherwise for some reason, even running as root.
# This is changed at the end of the install process anyways.
chown -R root:root /mnt
export HOME=/mnt/server

# Install game using SteamCMD
echo -e "${YELLOW}Installing Valheim server using SteamCMD...${NC}"
STEAMCMD_ATTEMPTS=3

for ((STEAMCMD_ATTEMPT=1; STEAMCMD_ATTEMPT<=STEAMCMD_ATTEMPTS; STEAMCMD_ATTEMPT++)); do
    if ./steamcmd.sh +force_install_dir /mnt/server +login ${STEAM_USER} ${STEAM_PASS} ${STEAM_AUTH} $( [[ "${WINDOWS_INSTALL}" == "1" ]] && printf %s '+@sSteamCmdForcePlatformType windows' ) +app_update ${SRCDS_APPID} $( [[ -z ${SRCDS_BETAID} ]] || printf %s "-beta ${SRCDS_BETAID}" ) $( [[ -z ${SRCDS_BETAPASS} ]] || printf %s "-betapassword ${SRCDS_BETAPASS}" ) ${INSTALL_FLAGS} validate +quit; then
        break
    fi

    if [ "$STEAMCMD_ATTEMPT" -eq "$STEAMCMD_ATTEMPTS" ]; then
        echo -e "${RED}Error: SteamCMD failed after $STEAMCMD_ATTEMPTS attempts${NC}"
        exit 1
    fi

    echo -e "${RED}SteamCMD attempt $STEAMCMD_ATTEMPT failed, retrying in 5 seconds...${NC}"
    sleep 5
done

# Set up 32 bit libraries
mkdir -p /mnt/server/.steam/sdk32
cp -v linux32/steamclient.so ../.steam/sdk32/steamclient.so

# Set up 64 bit libraries
mkdir -p /mnt/server/.steam/sdk64
cp -v linux64/steamclient.so ../.steam/sdk64/steamclient.so

echo -e "${GREEN}Valheim dedicated server installation completed.${NC}"

echo -e "${BLUE}-------------------------------------------------------${NC}"
echo -e "${YELLOW}---------Installing BepInEx and Specified Mods---------${NC}"
echo -e "${BLUE}-------------------------------------------------------${NC}"

if [ ! -z "$V_MODPACK" ]; then
    echo -e "${YELLOW}Retrieving ModPack metadata for: $V_MODPACK${NC}"

    # Modpack Name dashes to slashes for URL
    V_MODPACK_CONVERTED=$(echo "$V_MODPACK" | sed 's/-/\//g')
    V_MODPACK_URL="https://hexium.gg/api/experimental/package/${V_MODPACK_CONVERTED}/"

    # Attempt to retrieve ModPack info from Hexium API first. If it fails, fallback to Thunderstore API.
    if ! MODPACK_API_RESPONSE=$(curl -fsSL --max-time 5 -H "accept: application/json" "${V_MODPACK_URL}"); then
        echo -e "${RED}Error: Could not retrieve $V_MODPACK metadata from Hexium API${NC}"
        V_MODPACK_URL="https://thunderstore.io/api/experimental/package/${V_MODPACK_CONVERTED}/"

        # Attempt to retrieve ModPack info again, nagainst the Thunderstore API.
        if ! MODPACK_API_RESPONSE=$(curl -fsSL --max-time 5 -H "accept: application/json" "${V_MODPACK_URL}"); then
            echo -e "${RED}Error: Could not retrieve $V_MODPACK metadata from Thunderstore API${NC}"
            exit 1
        fi
    fi

    # Extract the version number and download URL from the API response
    BEPINEX_VERSION_NUMBER=$(jq -r '.dependencies[] | select(startswith("denikson-BepInExPack_Valheim-")) | split("-")[-1]' <<< "$MODPACK_API_RESPONSE")
    BEPINEX_DOWNLOAD_URL=$(curl -fsSL --max-time 5 -H "accept: application/json" "${V_MODPACK_URL%%/package/*}/package/denikson/BepInExPack_Valheim/${BEPINEX_VERSION_NUMBER}/" | jq -r ".download_url")
    MODPACK_DEPENDENCIES=$(jq -r '.dependencies[]' <<< "$MODPACK_API_RESPONSE")
    MODPACK_NAME=$(jq -r '.name' <<< "$MODPACK_API_RESPONSE")
    MODPACK_VERSION_NUMBER=$(jq -r '.version_number' <<< "$MODPACK_API_RESPONSE")
else
    echo -e "${YELLOW}No modpack specified, installing latest BepInEx${NC}"
    if ! LATEST_BEPINX_API_RESPONSE=$(curl -fsSL --max-time 5 -H "accept: application/json" "https://hexium.gg/api/experimental/package/denikson/BepInExPack_Valheim/"); then
        echo -e "${RED}Error: Could not retrieve BepInEx metadata from Hexium API${NC}"

        # Attempt to retrieve BepInEx info again, against the Thunderstore API.
        if ! LATEST_BEPINX_API_RESPONSE=$(curl -fsSL --max-time 5 -H "accept: application/json" "https://thunderstore.io/api/experimental/package/denikson/BepInExPack_Valheim/"); then
            echo -e "${RED}Error: Could not retrieve BepInEx metadata from Thunderstore API${NC}"
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

echo -e "${YELLOW}Downloading BepInEx ($BEPINEX_VERSION_NUMBER) from $BEPINEX_DOWNLOAD_URL${NC}"
if ! curl -fsS -o "$BEPINEX_FILENAME" "$BEPINEX_DOWNLOAD_URL"; then
    echo -e "${RED}Error: Failed to download BepInEx from $BEPINEX_DOWNLOAD_URL${NC}"
    exit 1
fi

if ! 7z x -y "$BEPINEX_FILENAME" >/dev/null; then
    echo -e "${RED}Error: Failed to extract BepInEx from $BEPINEX_FILENAME${NC}"
    exit 1
fi

cp -Rf ./BepInExPack_Valheim/* /mnt/server
mkdir -p /mnt/server/BepInEx/plugins
mkdir -p /mnt/server/BepInEx/patchers

echo -e "${GREEN}BepInEx installation completed.${NC}"

if [ ! -z "$V_MODPACK_URL" ]; then

    echo -e "${YELLOW}Downloading ModPack: $MODPACK_NAME ($MODPACK_VERSION_NUMBER) from $V_MODPACK_URL${NC}"

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
            echo -e "${RED}Error: Could not retrieve $MODPACK_DEPENDENCY metadata from Hexium API${NC}"
            MODPACK_DEPENDENCY_METADATA_URL="https://thunderstore.io/api/experimental/package/${MODPACK_DEPENDENCY_CONVERTED}/"

            # Attempt to retrieve dependency info again, against the Thunderstore API.
            if ! MODPACK_DEPENDENCY_API_RESPONSE=$(curl -fsSL --max-time 5 -H "accept: application/json" "${MODPACK_DEPENDENCY_METADATA_URL}"); then
                echo -e "${RED}Error: Could not retrieve $MODPACK_DEPENDENCY metadata from Thunderstore API${NC}"
                exit 1
            fi
        fi

        # Extract the version number and download URL from the API response
        MODPACK_DEPENDENCY_VERSION_NUMBER=$(jq -r  ".version_number" <<< "$MODPACK_DEPENDENCY_API_RESPONSE" )
        MODPACK_DEPENDENCY_DOWNLOAD_URL=$(jq -r  ".download_url" <<< "$MODPACK_DEPENDENCY_API_RESPONSE" )
        MODPACK_DEPENDENCY_NAME=$(jq -r  ".name" <<< "$MODPACK_DEPENDENCY_API_RESPONSE" )
        
        # Download dependencies
        echo -e "${YELLOW}Downloading $MODPACK_DEPENDENCY_NAME ($MODPACK_DEPENDENCY_VERSION_NUMBER) from $MODPACK_DEPENDENCY_DOWNLOAD_URL${NC}"
        
        MODPACK_DEPENDENCY_FILENAME=$(basename "${MODPACK_DEPENDENCY_DOWNLOAD_URL%%\?*}")
        if ! curl -fsSL -o "$MODPACK_DEPENDENCY_FILENAME" "$MODPACK_DEPENDENCY_DOWNLOAD_URL"; then
            echo -e "${RED}Error: Failed to download $MODPACK_DEPENDENCY_NAME ($MODPACK_DEPENDENCY_VERSION_NUMBER) from $MODPACK_DEPENDENCY_DOWNLOAD_URL${NC}"
            exit 1
        fi

        # Extract DLL files from the ZIP and delete the zip file
        DEPENDENCY_TEMP_DIR=$(mktemp -d)

        if ! 7z x -y "-o$DEPENDENCY_TEMP_DIR" "$MODPACK_DEPENDENCY_FILENAME" >/dev/null; then
            echo -e "${RED}Error: Failed to extract $MODPACK_DEPENDENCY_FILENAME${NC}"
            exit 1
        fi

        # Fix Windows-style backslashes in extracted paths
        for FILE in "$DEPENDENCY_TEMP_DIR"/*\\*; do
            [ -e "$FILE" ] || continue
            NEW_FILE="${FILE//\\//}"
            echo -e "${YELLOW}Fixing Windows-style backslashes in $FILE to $NEW_FILE${NC}"
            mkdir -p "$(dirname "$NEW_FILE")"
            mv "$FILE" "$NEW_FILE"
        done

        # Copy extracted DLL files to the appropriate BepInEx directories
        find "$DEPENDENCY_TEMP_DIR" -type f -name '*.dll' | while IFS= read -r FILE; do
            case "$FILE" in
                "$DEPENDENCY_TEMP_DIR"/BepInEx/patchers/*|"$DEPENDENCY_TEMP_DIR"/patchers/*)
                    echo -e "${YELLOW}Copying patcher DLL $FILE to BepInEx/patchers${NC}"
                    cp -f -- "$FILE" /mnt/server/BepInEx/patchers/
                    ;;
                *)
                    echo -e "${YELLOW}Copying plugin DLL $FILE to BepInEx/plugins${NC}"
                    cp -f -- "$FILE" /mnt/server/BepInEx/plugins/
                    ;;
            esac
        done

        # Clean up temporary files for the current dependency
        rm -Rf "$DEPENDENCY_TEMP_DIR"
        rm -f "$MODPACK_DEPENDENCY_FILENAME"

        echo -e "${GREEN}Installed dependency: $MODPACK_DEPENDENCY_NAME${NC}"
    done

    echo -e "${GREEN}All dependencies have been downloaded and installed successfully.${NC}"
fi

echo -e "${BLUE}-------------------------------------------------------${NC}"
echo -e "${YELLOW}------------------Cleanup TEMP Files-------------------${NC}"
echo -e "${BLUE}-------------------------------------------------------${NC}"

# Cleanup leftover files
echo -e "${YELLOW}Cleaning up temporary files...${NC}"
rm -Rf "$TEMP_DIR"
rm -Rf "$STEAM_TEMP_DIR"

echo -e "${BLUE}-------------------------------------------------------${NC}"
echo -e "${GREEN}----------Installation Completed Successfully----------${NC}"
echo -e "${BLUE}-------------------------------------------------------${NC}"