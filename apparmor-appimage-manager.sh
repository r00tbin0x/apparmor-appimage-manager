#!/bin/bash
# =============================================
# AppArmor AppImage Profile Manager
# Version: 3.12
# =============================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VERSION="3.12"

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
        success "Minimal permissive profile created: $final_name"
        return 0
    else
        error "Failed to load profile: $final_name"
        return 1
    fi
}

function reload_all_profiles() {
    echo -e "${YELLOW}Reloading all AppArmor profiles...${NC}"
    
    local success_count=0
    local fail_count=0

    for profile in /etc/apparmor.d/*; do
        [[ -f "$profile" ]] || continue
        local basename=$(basename "$profile")
        
        [[ $basename =~ ^(tunables|abstractions|local)$ ]] && continue
        [[ $basename =~ ^[a-zA-Z0-9_.-]+$ ]] || continue

        if apparmor_parser -r "$profile" 2>/dev/null; then
            ((success_count++))
        else
            ((fail_count++))
            echo -e "   ${RED}✗ Failed:${NC} $basename"
        fi
    done

    echo ""
    if [ $fail_count -eq 0 ]; then
        success "SUCCESS: All $success_count profiles reloaded successfully"
    else
        error "PARTIAL FAILURE: $success_count succeeded, $fail_count failed"
    fi
}

# ===================== MAIN MENU =====================
while true; do
    header
    echo "1) Create Permissive profile"
    echo "2) List all profiles"
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
        1)
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
                    pause
                    continue
                fi

                echo -e "${YELLOW}Found ${#APPIMAGES[@]} AppImage(s):${NC}"
                for i in "${!APPIMAGES[@]}"; do
                    echo "$((i+1))) ${APPIMAGES[$i]}"
                done

                read -rp "Select number: " num
                if [[ $num -lt 1 || $num -gt ${#APPIMAGES[@]} ]]; then
                    error "Invalid selection"
                    pause
                    continue
                fi
                appimage_path="$(pwd)/${APPIMAGES[$((num-1))]}"
            else
                read -rp "Enter full path to AppImage: " appimage_path
                if [ ! -f "$appimage_path" ]; then
                    error "AppImage not found."
                    pause
                    continue
                fi
            fi

            profile_name=$(basename "$appimage_path" | sed -E 's/\.(AppImage|appimage)$//I' | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-_')

            if [ -f "/etc/apparmor.d/${profile_name}-appimage" ]; then
                warning "Profile '${profile_name}-appimage' already exists."
                read -rp "Overwrite? (y/N): " yn
                [[ ! $yn =~ ^[Yy]$ ]] && { pause; continue; }
            fi

            create_permissive "$appimage_path" "$profile_name"
            ;;

        2)
            echo -e "${BLUE}=== All AppArmor Profiles ===${NC}"
            aa-status | head -n 120
            ;;

        3)
            echo -e "${BLUE}=== AppImage Profiles Only ===${NC}"
            mapfile -t appimage_profiles < <(ls /etc/apparmor.d/ 2>/dev/null | grep -E '^[a-z0-9_-]+-appimage$')
            
            if [ ${#appimage_profiles[@]} -eq 0 ]; then
                echo "No -appimage profiles found."
            else
                for p in "${appimage_profiles[@]}"; do
                    mode=$(aa-status 2>/dev/null | grep -E "^\s*$p" | awk '{print $2}' || echo "unknown")
                    printf "%-45s %s\n" "$p" "[$mode]"
                done
                echo -e "\n${GREEN}${#appimage_profiles[@]} AppImage profile(s) found${NC}"
            fi
            ;;

        4)
            echo -e "${BLUE}=== Available Profiles ===${NC}"
            ls /etc/apparmor.d/ 2>/dev/null | grep -E '^[a-z0-9_.-]+$' | sort || echo "No profiles found"
            echo ""
            read -rp "Enter profile name to edit: " p

            if [ -f "/etc/apparmor.d/$p" ]; then
                nano "/etc/apparmor.d/$p"
                echo -e "\n${YELLOW}Reload this profile now? (y/N)${NC}"
                read -rp "" reload
                if [[ $reload =~ ^[Yy]$ ]]; then
                    apparmor_parser -r "/etc/apparmor.d/$p" && success "Profile reloaded" || error "Failed to reload"
                fi
            else
                error "Profile not found: $p"
            fi
            ;;

        5)
            echo -e "${BLUE}Available profiles:${NC}"
            ls /etc/apparmor.d/ 2>/dev/null | grep -E '^[a-z0-9_.-]+$' | sort || echo "No profiles found"
            echo ""
            read -rp "Enter profile name to delete: " p

            if [ -f "/etc/apparmor.d/$p" ]; then
                read -rp "Delete '$p'? (y/N): " c
                if [[ $c =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}Deleting $p...${NC}"
                    rm -f "/etc/apparmor.d/$p"
                    aa-disable "$p" >/dev/null 2>&1 || true
                    success "Profile '$p' deleted successfully"
                fi
            else
                error "Profile not found: $p"
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
            echo -e "${BLUE}Help${NC}"
            echo "• Option 3 should now work"
            echo "• Option 6 returns to menu properly"
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
