#!/bin/bash
# =============================================
# AppArmor AppImage Profile Manager
# Version: 3.23
# =============================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VERSION="3.23"

# ===================== ROOT & DEPENDENCIES =====================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}✗ This script must be run as root (use sudo)${NC}"
    exit 1
fi

for cmd in apparmor_parser aa-status aa-enforce aa-complain aa-disable; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}✗ Missing command: $cmd${NC}"
        echo -e "${YELLOW}→ Run: sudo apt install apparmor-utils${NC}"
        exit 1
    fi
done

# ===================== FUNCTIONS =====================
function header() {
    clear
    echo -e "${BLUE}=============================================${NC}"
    echo -e "${BLUE}   AppArmor AppImage Profile Manager${NC}"
    echo -e "${BLUE}               v${VERSION}${NC}"
    echo -e "${BLUE}=============================================${NC}"
    echo ""
}

function success() { echo -e "${GREEN}✓ $1${NC}"; }
function warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
function error()   { echo -e "${RED}✗ $1${NC}"; }

function pause() {
    echo ""
    read -rp "Press Enter to return to main menu..."
}

# ==================== CLEAN PROFILE NAME ====================
function sanitize_profile_name() {
    local filename=$(basename "$1")
    local base="${filename%.*}"

    local clean="$base"

    clean=$(echo "$clean" | sed -E 's/[-._]([0-9]{5,}[a-z0-9]*|[0-9]+\.[0-9]+|20[0-9]{2}|[0-9]{1,3}\.[0-9]).*//i')
    clean=$(echo "$clean" | sed -E 's/[-._](x86_64|amd64|arm64|aarch64|i386|ia32|linux|gtk|qt).*//i')
    clean=$(echo "$clean" | sed -E 's/[-._][0-9]{5,}[a-z0-9]*//i')

    clean=$(echo "$clean" | tr '[:upper:]' '[:lower:]' \
                          | tr -cs '[:alnum:]-' '-' \
                          | sed 's/--*/-/g' \
                          | sed 's/^-//;s/-$//')

    if [ -z "$clean" ] || [ ${#clean} -le 2 ]; then
        clean=$(echo "$base" | tr '[:upper:]' '[:lower:]' | cut -d'-' -f1-2)
    fi

    echo "$clean"
}

# ==================== SMART WILDCARD ====================
function generate_wildcard_pattern() {
    local fullpath="$1"
    local dirname=$(dirname "$fullpath")
    local filename=$(basename "$fullpath")
    local base="${filename%.*}"

    local cleaned=$(echo "$base" | sed -E 's/[-._]([0-9]{5,}[a-z0-9]*|[0-9]+\.[0-9]+|20[0-9]{2}|[0-9]{1,3}\.[0-9]).*//i')
    cleaned=$(echo "$cleaned" | sed -E 's/[-._](x86_64|amd64|arm64|aarch64|linux|gtk|qt).*//i')

    if [[ "$cleaned" == "$base" ]] || [[ -z "$cleaned" ]]; then
        cleaned=$(echo "$base" | sed -E 's/[-._][0-9].*//')
    fi

    echo "${dirname}/${cleaned}*"
}

function create_permissive() {
    local appimage_path="$1"
    local profile_name="$2"
    local final_name="${profile_name}-appimage"

    cat > "/etc/apparmor.d/$final_name" << EOF
# This profile allows everything and only exists to give the
# application a name instead of having the label "unconfined"
# Generated: $(date)
# Original AppImage: $appimage_path

abi <abi/4.0>,
include <tunables/global>

profile $final_name "$appimage_path" flags=(default_allow) {
    userns,

    include if exists <local/$final_name>
}
EOF

    if apparmor_parser -r "/etc/apparmor.d/$final_name" 2>/dev/null; then
        success "Profile created → ${final_name}"
        return 0
    else
        error "Failed to load profile: $final_name"
        return 1
    fi
}

function create_permissive_wildcard() {
    local pattern="$1"
    local profile_name="$2"
    local final_name="${profile_name}-appimage"

    cat > "/etc/apparmor.d/$final_name" << EOF
# Wildcard profile for versioned AppImages
# Generated: $(date)
# Path Pattern: $pattern

abi <abi/4.0>,
include <tunables/global>

profile $final_name "$pattern" flags=(default_allow) {
    userns,

    include if exists <local/$final_name>
}
EOF

    if apparmor_parser -r "/etc/apparmor.d/$final_name" 2>/dev/null; then
        success "Wildcard profile created → ${final_name}"
        echo -e "${YELLOW}→ Pattern: $pattern${NC}"
        return 0
    else
        error "Failed to load profile"
        return 1
    fi
}

function reload_all_profiles() {
    echo -e "${YELLOW}Reloading all AppArmor profiles...${NC}"
    
    local success_count=0
    local fail_count=0
    local failed_profiles=""

    for profile in /etc/apparmor.d/*; do
        [[ -f "$profile" ]] || continue
        local basename=$(basename "$profile")
        
        [[ $basename =~ ^(tunables|abstractions|local)$ ]] && continue
        [[ $basename =~ ^[a-zA-Z0-9_.-]+$ ]] || continue

        if apparmor_parser -r "$profile" 2>/dev/null; then
            ((success_count++))
        else
            ((fail_count++))
            failed_profiles="$failed_profiles   ✗ $basename\n"
        fi
    done

    echo ""
    if [ $fail_count -eq 0 ]; then
        success "SUCCESS: All $success_count profiles reloaded successfully"
    else
        error "PARTIAL FAILURE: $success_count succeeded, $fail_count failed"
        echo -e "$failed_profiles"
    fi
}

# ===================== MAIN MENU =====================
while true; do
    header
    echo "1) Create Permissive profile (Exact filename)"
    echo "2) Create Permissive profile with Wildcard (Recommended)"
    echo "3) List AppImage profiles only"
    echo "4) Edit profile with Nano"
    echo "5) Delete profile"
    echo "6) Reload all profiles"
    echo "7) Show AppArmor status"
    echo "8) Help"
    echo "9) Exit"
    echo ""

    read -rp "Select option (1-9): " choice

    case $choice in
        1|2)
            if [ "$choice" -eq 1 ]; then
                mode="Exact"
            else
                mode="Wildcard"
            fi

            echo -e "\n${YELLOW}Create ${mode} Profile${NC}"
            echo -e "\n${YELLOW}Select AppImage:${NC}"
            echo "1) Scan current folder"
            echo "2) Enter full path manually"
            read -rp "Choose (1 or 2): " sub

            if [ "$sub" = "1" ]; then
                shopt -s nullglob
                APPIMAGES=(*.AppImage *.appimage)
                shopt -u nullglob
                if [ ${#APPIMAGES[@]} -eq 0 ]; then
                    error "No AppImages found in current directory."
                    pause; continue
                fi
                echo -e "${YELLOW}Found ${#APPIMAGES[@]} AppImage(s):${NC}"
                for i in "${!APPIMAGES[@]}"; do echo "$((i+1))) ${APPIMAGES[$i]}"; done
                read -rp "Select number: " num
                if [[ $num -lt 1 || $num -gt ${#APPIMAGES[@]} ]]; then
                    error "Invalid selection"; pause; continue
                fi
                appimage_path="$(pwd)/${APPIMAGES[$((num-1))]}"
            else
                read -rp "Enter full path to AppImage: " appimage_path
                [ ! -f "$appimage_path" ] && { error "AppImage not found."; pause; continue; }
            fi

            profile_name=$(sanitize_profile_name "$appimage_path")
            echo -e "${YELLOW}Generated profile name:${NC} ${BLUE}${profile_name}-appimage${NC}"

            if [ -f "/etc/apparmor.d/${profile_name}-appimage" ]; then
                warning "Profile already exists."
                read -rp "Overwrite? (y/N): " yn
                [[ ! $yn =~ ^[Yy]$ ]] && { pause; continue; }
            fi

            if [ "$choice" -eq 1 ]; then
                create_permissive "$appimage_path" "$profile_name"
            else
                wildcard_pattern=$(generate_wildcard_pattern "$appimage_path")
                echo -e "${YELLOW}Proposed pattern:${NC} ${BLUE}$wildcard_pattern${NC}"
                read -rp "Create with this pattern? (y/N): " confirm
                [[ ! $confirm =~ ^[Yy]$ ]] && { echo "Cancelled."; pause; continue; }
                create_permissive_wildcard "$wildcard_pattern" "$profile_name"
            fi
            ;;

        3)
            echo -e "${BLUE}=== AppImage Profiles Only ===${NC}"
            mapfile -t appimage_profiles < <(find /etc/apparmor.d -maxdepth 1 -name '*-appimage' -printf '%f\n' | sort)
            if [ ${#appimage_profiles[@]} -eq 0 ]; then
                echo "No profiles found."
            else
                for p in "${appimage_profiles[@]}"; do
                    mode=$(aa-status 2>/dev/null | grep -E "^\s*$p" | awk '{print $2}' || echo "unknown")
                    printf "%-45s [%s]\n" "$p" "$mode"
                done
                echo -e "\n${GREEN}${#appimage_profiles[@]} profile(s)${NC}"
            fi
            ;;

        4)
            echo -e "${BLUE}=== Available Profiles ===${NC}"
            ls /etc/apparmor.d/ 2>/dev/null | grep -E '^[a-z0-9_.-]+$' | sort
            echo ""
            read -rp "Enter profile name to edit: " p
            if [ -f "/etc/apparmor.d/$p" ]; then
                nano "/etc/apparmor.d/$p"
                read -rp "Reload now? (y/N): " r
                [[ $r =~ ^[Yy]$ ]] && apparmor_parser -r "/etc/apparmor.d/$p" && success "Profile reloaded"
            else
                error "Profile not found"
            fi
            ;;

        5)
            echo -e "${BLUE}Available profiles:${NC}"
            ls /etc/apparmor.d/ 2>/dev/null | grep -E '^[a-z0-9_.-]+$' | sort
            echo ""
            read -rp "Enter profile name to delete: " p
            if [ -f "/etc/apparmor.d/$p" ]; then
                read -rp "Delete '$p'? (y/N): " c
                if [[ $c =~ ^[Yy]$ ]]; then
                    rm -f "/etc/apparmor.d/$p"
                    aa-disable "$p" >/dev/null 2>&1 || true
                    success "Profile deleted"
                fi
            else
                error "Profile not found"
            fi
            ;;

        6)
            reload_all_profiles
            ;;

        7)
            echo -e "${BLUE}=== AppArmor Status ===${NC}"
            aa-status
            ;;

        8)
            header
            echo -e "${BLUE}=== Detailed Help ===${NC}"
            echo ""
            echo -e "1) ${YELLOW}Exact Filename Profile${NC}"
            echo "   Creates a profile that matches only one specific AppImage file."
            echo "   Best when the filename never changes."
            echo ""
            echo -e "2) ${YELLOW}Wildcard Profile (Recommended)${NC}"
            echo "   Automatically creates a pattern like AppName-*"
            echo "   Ideal for AppImages that update and change version numbers."
            echo "   Includes smart name cleaning and preview before creation."
            echo ""
            echo -e "3) ${YELLOW}List AppImage Profiles${NC}"
            echo "   Shows only profiles created by this tool (ending with -appimage)."
            echo ""
            echo -e "4) ${YELLOW}Edit Profile with Nano${NC}"
            echo "   Opens the selected profile in Nano editor for manual tweaking."
            echo "   Recommended after creating a permissive profile."
            echo ""
            echo -e "5) ${YELLOW}Delete Profile${NC}"
            echo "   Completely removes a profile from AppArmor."
            echo ""
            echo -e "6) ${YELLOW}Reload All Profiles${NC}"
            echo "   Reloads every AppArmor profile on the system."
            echo ""
            echo -e "7) ${YELLOW}Show AppArmor Status${NC}"
            echo "   Displays current enforcement status and loaded profiles."
            echo ""
            echo -e "Tip: After editing a profile (Option 4), always reload it."
            echo "Wildcard profiles are the best choice for most modern AppImages."
            pause
            ;;

        9)
            echo -e "${GREEN}Goodbye!${NC}"
            exit 0
            ;;

        *)
            error "Invalid option"
            ;;
    esac

    pause
done
