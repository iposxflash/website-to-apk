#!/usr/bin/env bash
set -eu

# Color definitions
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color
readonly BOLD='\033[1m'

# Info for keystore generation
INFO="CN=Developer, OU=Organization, O=Company, L=City, S=State, C=US"

# --- Logging Functions ---

log() {
    echo -e "${GREEN}[+]${NC} $1"
}

info() {
    echo -e "${BLUE}[*]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

error() {
    echo -e "${RED}[!]${NC} $1"
    exit 1
}

try() {
    local log_file=$(mktemp)
    
    if [ $# -eq 1 ]; then
        if ! eval "$1" &> "$log_file"; then
            echo -e "${RED}[!]${NC} Failed: $1"
            cat "$log_file"
            rm -f "$log_file"
            exit 1
        fi
    else
        if ! "$@" &> "$log_file"; then
            echo -e "${RED}[!]${NC} Failed: $*"
            cat "$log_file"
            rm -f "$log_file"
            exit 1
        fi
    fi
    rm -f "$log_file"
}

# --- Variable Setting Function ---

set_var() {
    # PERBAIKAN: Menggunakan pemisahan string yang lebih aman dan eksplisit
    local input="$1"
    local var_name="${input%%=*}"
    local raw_value="${input#*=}"

    local var_name=$(echo "$var_name" | xargs)
    local new_value=$(echo "$raw_value" | xargs)
    
    [ -z "$new_value" ] && error "Empty value provided for $var_name"

    # 1. Menentukan Lokasi MainActivity.java secara Dinamis
    local java_file
    java_file=$(find app/src/main/java -name "MainActivity.java" -type f | head -n 1)

    if [ -z "$java_file" ]; then
        java_file="app/src/main/java/$(echo "com.$appname" | tr . /)/MainActivity.java"
    fi

    [ ! -f "$java_file" ] && error "MainActivity.java not found"
    
    # 2. Memeriksa Keberadaan Variabel
    if ! grep -q "[[:space:]]$var_name[[:space:]]*=.*;" "$java_file"; then
        error "Variable '$var_name' not found in MainActivity.java"
    fi

    # 3. Memformat Nilai Baru
    if [[ ! "$new_value" =~ ^(true|false)$ ]]; then
        local safe_value="${new_value//\"/\\\"}" 
        new_value="\"$safe_value\""
    fi
    
    local tmp_file=$(mktemp)
    
    # 4. Substitusi dengan sed
    local escaped_var_name="${var_name//./\\.}"
    local escaped_new_value="${new_value//&/\\&}" 

    try "sed '/[[:space:]]'"$escaped_var_name"'[[:space:]]*=/ s|=.*;|= '"$escaped_new_value"';|' "$java_file" > "$tmp_file"

    # 5. Menerapkan Perubahan
    if ! diff -q "$java_file" "$tmp_file" >/dev/null; then
        mv "$tmp_file" "$java_file"
        log "Updated $var_name to $new_value"
        if [ "$var_name" = "geolocationEnabled" ]; then
            update_geolocation_permission ${new_value//\"/}
        fi
    else
        rm "$tmp_file"
    fi
}
    
# --- Configuration Merge Function ---

merge_config_with_default() {
    local default_conf="app/default.conf"
    local user_conf="$1"
    local merged_conf
    merged_conf=$(mktemp)

    local temp_defaults
    temp_defaults=$(mktemp)

    while IFS= read -r line; do
        key=$(echo "$line" | cut -d '=' -f1 | xargs)
        if [ -n "$key" ]; then
            if ! grep -q -E "^[[:space:]]*$key[[:space:]]*=" "$user_conf"; then
                echo "$line" >> "$temp_defaults"
            fi
        fi
    done < <(grep -vE '^[[:space:]]*(#|$)' "$default_conf")

    cat "$temp_defaults" "$user_conf" > "$merged_conf"

    rm -f "$temp_defaults"
    echo "$merged_conf"
}

# --- Apply Config Function ---

apply_config() {
    local config_file="${1:-webapk.conf}"

    if [ ! -f "$config_file" ] && [ -f "$ORIGINAL_PWD/$config_file" ]; then
        config_file="$ORIGINAL_PWD/$config_file"
    fi

    [ ! -f "$config_file" ] && error "Config file not found: $config_file"

    export CONFIG_DIR="$(dirname "$config_file")"

    info "Using config: $config_file"

    config_file=$(merge_config_with_default "$config_file")
    
    while IFS='=' read -r key value || [ -n "$key" ]; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        
        case "$key" in
            "id")
                chid "$value"
                ;;
            "name")
                rename "$value"
                ;;
            "deeplink")
                set_deep_link "$value"
                ;;
            "trustUserCA")
                set_network_security_config "$value"
                ;;
            "icon")
                set_icon "$value"
                ;;
            "scripts")
                set_userscripts $value
                ;;
            *)
                # PENTING: Panggil set_var dengan format "key = value"
                set_var "$key = $value"
                ;;
        esac
    done < <(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]\+#.*//' "$config_file")
}

# --- APK Build Function ---

apk() {
    if [ ! -f "app/my-release-key.jks" ]; then
        error "Keystore file not found. Run './make.sh keygen' first"
    fi

    rm -f app/build/outputs/apk/release/app-release.apk

    info "Building APK..."
    try "./gradlew assembleRelease --no-daemon --quiet"

    if [ -f "app/build/outputs/apk/release/app-release.apk" ]; then
        log "APK successfully built and signed"
        try "cp app/build/outputs/apk/release/app-release.apk '$appname.apk'"
        echo -e "${BOLD}----------------"
        echo -e "Final APK copied to: ${GREEN}$appname.apk${NC}"
        echo -e "Size: ${BLUE}$(du -h app/build/outputs/apk/release/app-release.apk | cut -f1)${NC}"
        echo -e "Package: ${BLUE}com.${appname}${NC}" 
        echo -e "App name: ${BLUE}$(grep -o 'app_name">[^<]*' app/src/main/res/values/strings.xml | cut -d'>' -f2)${NC}"
        echo -e "URL: ${BLUE}$(grep 'String mainURL' app/src/main/java/$(echo "com.$appname" | tr . /)/MainActivity.java | cut -d'"' -f2)${NC}"
        echo -e "${BOLD}----------------${NC}"
    else
        error "Build failed"
    fi
}

# --- Test Function ---

test() {
    # PERBAIKAN: Mengganti grep -oP dengan awk yang lebih andal
    info "Detected app name: $appname"
    try "adb install app/build/outputs/apk/release/app-release.apk"
    try "adb logcat -c" # clean logs
    try "adb shell am start -n com.$appname/.MainActivity" 
    echo "=========================="

    # AWK adalah solusi yang lebih baik dan lebih universal untuk mengekstrak string log
    adb logcat -d | awk '/WebToApk: / { sub(/.*WebToApk: /, ""); print }'
}

# --- Keystore Generation Function (Non-Interaktif) ---

keygen() {
    # PERBAIKAN: Non-interaktif untuk CI/CD (tidak ada read -p)
    if [ -f "app/my-release-key.jks" ]; then
        warn "Keystore app/my-release-key.jks already exists. Skipping key generation."
        return 0
    fi
    
    info "Generating new release key (my-release-key.jks)..."
    
    try "keytool -genkey -v -keystore app/my-release-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias my -storepass '123456' -keypass '123456' -dname '$INFO'"
    
    log "Keystore generated successfully at app/my-release-key.jks."
}

# --- Clean Function ---

clean() {
    info "Cleaning build files..."
    try rm -rf app/build .gradle
    apply_config app/default.conf
    log "Clean completed"
}

# --- Change Application ID (chid) Function ---

chid() {
    [ -z "$1" ] && error "Please provide an application ID"

    local new_full_id="$1"
    
    if ! [[ $new_full_id =~ ^[a-z0-9]+(\.[a-z0-9]+)*$ ]]; then
        error "Invalid application ID format. Use only lowercase letters, numbers, and dots (e.g., com.myapp.project)"
    fi

    local old_full_id
    old_full_id=$(grep -Po 'applicationId\s+"(.*?)"' app/build.gradle | cut -d'"' -f2 || echo "com.myexample.webtoapk") 
    
    if [ "$old_full_id" = "$new_full_id" ]; then
        log "Application ID already set to $new_full_id. No changes needed."
        return 0
    fi

    local old_base_part="${old_full_id%.*}"         
    local old_dir_part="${old_full_id##*.}"         

    local new_base_part="${new_full_id%.*}"         
    local new_dir_part="${new_full_id##*.}"         
    
    local old_full_dir="app/src/main/java/${old_base_part//./\/}/$old_dir_part"
    local new_base_dir="app/src/main/java/${new_base_part//./\/}"
    local new_full_dir="$new_base_dir/$new_dir_part"
    
    if [ ! -d "$old_full_dir" ]; then
        warn "Old package directory not found: $old_full_dir. Assuming files are in default location."
    else
        info "Renaming directory structure from '$old_base_part/$old_dir_part' to '$new_base_part/$new_dir_part'"
        
        try "mkdir -p $new_full_dir"
        try "mv $old_full_dir/* $new_full_dir/"
        
        info "Cleaning up old package directories..."
        try "rm -rf $old_full_dir"
        
        # PERBAIKAN: Hapus direktori kosong (misal: com/myexample) dengan aman.
        local old_base_path="app/src/main/java/${old_base_part//./\/}"
        try "find $old_base_path -depth -type d -empty -delete"
    fi


    info "Updating all package references from '$old_full_id' to '$new_full_id'"

    local escaped_old_id="${old_full_id//./\\.}"
    
    try "find . -type f \\( -name '*.gradle' -o -name '*.java' -o -name '*.xml' -o -name '*.properties' -o -name '*.sh' \\) -exec \
        sed -i \"s#$escaped_old_id#$new_full_id#g\" {} +"
        
    # 5. Update the 'appname' global variable
    local new_appname_part="${new_full_id#com.}" 
    appname="$new_appname_part" 
    
    log "Application ID changed successfully to $new_full_id"
}

# --- Rename Function (Dihilangkan untuk meringkas) ---
rename() {
    local new_name="$*"
    # ... kode fungsi rename ...
    # ...
}

# ... (Semua fungsi lain yang tidak diubah seperti set_deep_link, set_network_security_config, set_icon, set_userscripts, update_geolocation_permission, get_tools, regradle, get_java, check_and_find_java harus ada di sini) ...

# --- System Check and Execution ---

build() {
    apply_config $@
    apk
}

###############################################################################

ORIGINAL_PWD="$PWD"

try cd "$(dirname "$0")"

export ANDROID_HOME=$PWD/cmdline-tools/
# PERBAIKAN: Menggunakan head -n 1 agar lebih eksplisit dalam mengambil nilai appname
appname=$(grep -Po '(?<=applicationId "com\.)[^"]*' app/build.gradle | head -n 1 || echo "myexample.webtoapk") 

export GRADLE_USER_HOME=$PWD/.gradle-cache

command -v wget >/dev/null 2>&1 || error "wget not found. Please install wget"

# Try to find Java 17
if ! check_and_find_java; then
    # PERBAIKAN: Non-interaktif
    warn "Java 17 not found. Attempting to download OpenJDK 17 to ./jvm..."
    get_java
    if ! command -v java >/dev/null 2>&1; then
        error "Java installation failed. Java 17 is required."
    fi
fi

# Final verification
java_version=$(java -version 2>&1 | head -n 1 | cut -d'"' -f2 | cut -d'.' -f1)
if [ "$java_version" != "17" ]; then
    error "Wrong Java version: $java_version. Java 17 is required"
fi

command -v adb >/dev/null 2>&1 || warn "adb not found. './make.sh try' will not work"

if [ ! -d "$ANDROID_HOME" ]; then
    # PERBAIKAN: Non-interaktif
    warn "Android Command Line Tools not found: ./cmdline-tools"
    info "Downloading Android Command Line Tools automatically..."
    get_tools
    if [ ! -d "$ANDROID_HOME" ]; then
        error "Cannot continue without Android Command Line Tools"
    fi
fi

if [ $# -eq 0 ]; then
    echo -e "${BOLD}Usage:${NC}"
    echo -e "  ${BLUE}$0 keygen${NC}      - Generate signing key"
    echo -e "  ${BLUE}$0 build${NC} [config]  - Apply configuration and build"
    echo -e "  ${BLUE}$0 test${NC}          - Install and test APK via adb, show logs"
    echo -e "  ${BLUE}$0 clean${NC}         - Clean build files, reset settings"
    echo 
    echo -e "  ${BLUE}$0 apk${NC}           - Build APK without apply_config"
    echo -e "  ${BLUE}$0 apply_config${NC}  - Apply settings from config file"
    echo -e "  ${BLUE}$0 get_java${NC}      - Download OpenJDK 17 locally"
    echo -e "  ${BLUE}$0 regradle${NC}      - Reinstall gradle. You don't need it"
    exit 1
fi

eval $@
