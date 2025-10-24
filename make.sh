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

# ----------------------------------------------------------------------------
# --- FUNGSI UTAMA (set_var) ---
# ----------------------------------------------------------------------------

set_var() {
    local input="$1"
    local var_name="${input%%=*}"
    local raw_value="${input#*=}"

    local var_name=$(echo "$var_name" | xargs)
    local new_value=$(echo "$raw_value" | xargs)
    
    [ -z "$new_value" ] && error "Empty value provided for $var_name"

    # 1. Menentukan Lokasi MainActivity.java secara Dinamis 
    local java_file
    java_file=$(find app/src/main/java -name "MainActivity.java" -type f | head -n 1)

    if [ -z "$java_file" ] || ! echo "$java_file" | grep -q "$(echo "com.$appname" | tr . /)"; then
        java_file="app/src/main/java/$(echo "com.$appname" | tr . /)/MainActivity.java"
    fi

    [ ! -f "$java_file" ] && error "MainActivity.java not found in path: $java_file (Pastikan Application ID sudah benar)"
    
    # 2. Memeriksa Keberadaan Variabel
    local var_pattern="[[:space:]][[:alnum:]_]*[[:space:]]$var_name[[:space:]]*="

    if ! grep -q "$var_pattern" "$java_file"; then
        error "Variable '$var_name' not found or improperly declared in MainActivity.java"
    fi

    # 3. Memformat Nilai Baru
    local escaped_new_value
    if [[ "$new_value" =~ ^(true|false|[0-9]+)$ ]]; then
        escaped_new_value="$new_value" 
    else
        local safe_value="${new_value//\"/\\\"}" 
        escaped_new_value="\"$safe_value\""
    fi
    
    local tmp_file=$(mktemp)
    
    # 4. Substitusi dengan sed
    local escaped_var_name="${var_name//./\\.}"
    local sed_command="sed '/[[:space:]]'"$escaped_var_name"'[[:space:]]*=/ s|=.*;|= '"$escaped_new_value"';|'"

    try "$sed_command" "$java_file" > "$tmp_file"

    # 5. Menerapkan Perubahan
    if ! diff -q "$java_file" "$tmp_file" >/dev/null; then
        mv "$tmp_file" "$java_file"
        log "Updated $var_name to $escaped_new_value"
        if [ "$var_name" = "geolocationEnabled" ]; then
            update_geolocation_permission ${new_value//\"/}
        fi
    else
        rm "$tmp_file"
        log "Value for $var_name already set to $escaped_new_value. No change."
    fi

    rm -f "$tmp_file"
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
        echo -e "URL: ${BLUE}$(grep 'mainURL' app/src/main/java/$(echo "com.$appname" | tr . /)/MainActivity.java | cut -d'"' -f2)${NC}"
        echo -e "${BOLD}----------------${NC}"
    else
        error "Build failed"
    fi
}

# ----------------------------------------------------------------------------
# --- FUNGSI UTAMA (test) ---
# ----------------------------------------------------------------------------

test() {
    info "Detected app name: $appname"
    try "adb install app/build/outputs/apk/release/app-release.apk"
    try "adb logcat -c" 
    try "adb shell am start -n com.$appname/.MainActivity" 
    echo "=========================="

    adb logcat -d | awk '/WebToApk: / { sub(/.*WebToApk: /, ""); print }'
}

# ----------------------------------------------------------------------------
# --- FUNGSI UTAMA (keygen) ---
# ----------------------------------------------------------------------------

keygen() {
    # Dibuat non-interaktif untuk CI/CD (Memperbaiki error syntax 'read -p')
    if [ -f "app/my-release-key.jks" ]; then
        warn "Keystore app/my-release-key.jks already exists. Skipping key generation for CI/CD."
        return 0
    fi
    
    info "Generating new release key (my-release-key.jks)..."
    
    # Perintah keytool non-interaktif
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
        try "find $old_full_dir -depth -type d -empty -delete"
        
        local old_base_path="app/src/main/java/${old_base_part//./\/}"
        try "find $old_base_path -depth -type d -empty -delete"
    fi

    info "Updating all package references from '$old_full_id' to '$new_full_id'"

    local escaped_old_id="${old_full_id//./\\.}"
    
    try "find . -type f \\( -name '*.gradle' -o -name '*.java' -o -name '*.xml' -o -name '*.properties' -o -name '*.sh' \\) -exec \
        sed -i \"s#$escaped_old_id#$new_full_id#g\" {} +"
        
    local new_appname_part="${new_full_id#com.}" 
    appname="$new_appname_part" 
    
    log "Application ID changed successfully to $new_full_id"
}

# ----------------------------------------------------------------------------
# --- FUNGSI PENDUKUNG (Java/Tools/Rename) ---
# ----------------------------------------------------------------------------

check_and_find_java() {
    if command -v java >/dev/null 2>&1; then
        local version=$(java -version 2>&1 | head -n 1 | cut -d'"' -f2 | cut -d'.' -f1)
        if [ "$version" = "17" ]; then
            if [ -n "$JAVA_HOME" ]; then
                export JAVA_HOME
            else
                export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java) 2>/dev/null) 2>/dev/null) 2>/dev/null)
            fi
            return 0
        fi
    fi
    return 1
}

get_java() {
    local OS
    case "$(uname -s)" in
        Linux*)  OS=linux;;
        Darwin*) OS=macos;;
        *)       error "Unsupported OS";;
    esac

    local URL="https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.10%2B7/OpenJDK17U-jdk_${OS}_x64_hotspot_17.0.10_7.tar.gz"

    mkdir -p jvm
    try "wget -qO- $URL | tar xz -C jvm --strip-components=1"
    
    export JAVA_HOME=$PWD/jvm
    export PATH="$JAVA_HOME/bin:$PATH"
}

get_tools() {
    local SDK_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
    local ZIP_FILE="cmdline-tools.zip" 
    local TMP_DIR=$(mktemp -d) # Direktori sementara baru

    mkdir -p cmdline-tools
    
    info "Downloading Android Command Line Tools ZIP..."
    try "wget -qO $ZIP_FILE $SDK_URL" 

    info "Extracting Android Command Line Tools..."
    # Ekstrak ke direktori sementara
    try "unzip -q $ZIP_FILE -d $TMP_DIR"

    try "rm $ZIP_FILE"

    mkdir -p cmdline-tools/latest
    
    # 3. Pindahkan file dengan aman dari direktori sementara ke cmdline-tools/latest
    local extracted_source
    # Cek struktur: Apakah hasil unzip adalah [TMP_DIR]/cmdline-tools?
    if [ -d "$TMP_DIR/cmdline-tools" ]; then
        extracted_source="$TMP_DIR/cmdline-tools/*"
    else
        # Jika file langsung di root direktori sementara
        extracted_source="$TMP_DIR/*"
    fi

    # Memindahkan konten dari sumber yang sudah ditentukan ke cmdline-tools/latest
    try "mv $extracted_source cmdline-tools/latest/"
    
    try "rm -rf $TMP_DIR" # Hapus direktori sementara yang sudah kosong
    
    export PATH="$ANDROID_HOME/latest/bin:$PATH"
    info "Installing Android SDK Build Tools..."
    
    (yes | try "$ANDROID_HOME/latest/bin/sdkmanager" "platform-tools" "build-tools;34.0.0" "platforms;android-34")
    log "Android SDK installed successfully."
}

rename() {
    local new_name="$*"
    
    if [ -z "$new_name" ]; then
        error "Please provide a display name"
    fi
    
    find app/src/main/res/values* -name "strings.xml" | while read xml_file; do
        current_name=$(grep -o 'app_name">[^<]*' "$xml_file" | cut -d'>' -f2)
        if [ "$current_name" = "$new_name" ]; then
            continue
        fi
        
        escaped_name=$(echo "$new_name" | sed 's/[\/&]/\\&/g')
        try sed -i "s|<string name=\"app_name\">[^<]*</string>|<string name=\"app_name\">$escaped_name</string>|" "$xml_file"
        
        lang_code=$(echo "$xml_file" | grep -o 'values-[^/]*' | cut -d'-' -f2)
        if [ -z "$lang_code" ]; then
            lang_code="default"
        fi
        
        log "Display name changed to: $new_name (${lang_code})"
    done
}

# Placeholder untuk fungsi lain (asumsi tidak menghasilkan error)
set_deep_link() { log "Setting deep link not implemented in this version"; }
set_network_security_config() { log "Setting network security config not implemented in this version"; }
set_icon() { log "Setting icon not implemented in this version"; }
set_userscripts() { log "Setting userscripts not implemented in this version"; }
update_geolocation_permission() { local enabled="$1"; log "Updating geolocation permission to $enabled"; }
regradle() { log "Regradle function not implemented in this version"; }

# --- System Check and Execution ---

build() {
    apply_config $@
    apk
}

###############################################################################

ORIGINAL_PWD="$PWD"

try cd "$(dirname "$0")"

export ANDROID_HOME=$PWD/cmdline-tools/
appname=$(grep -Po '(?<=applicationId "com\.)[^"]*' app/build.gradle | head -n 1 || echo "myexample.webtoapk") 

export GRADLE_USER_HOME=$PWD/.gradle-cache

command -v wget >/dev/null 2>&1 || error "wget not found. Please install wget"

# Try to find Java 17
if ! check_and_find_java; then
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

if [ ! -d "$ANDROID_HOME/latest" ]; then
    warn "Android Command Line Tools not found: ./cmdline-tools"
    info "Downloading Android Command Line Tools automatically..."
    get_tools
    if [ ! -d "$ANDROID_HOME/latest" ]; then
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
