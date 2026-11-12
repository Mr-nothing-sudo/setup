#!/usr/bin/env bash
# ScrollSlayer Android development environment installer
# Safe to rerun: installs missing tools and preserves existing projects/configuration.
# Target: Ubuntu / Linux Mint, x86_64, Zsh preferred.
#
# Usage:
#   chmod +x install-android-dev.sh
#   ./install-android-dev.sh
#
# Optional:
#   ANDROID_API_LEVELS="34 36" ./install-android-dev.sh

set -Eeuo pipefail

NVM_VERSION="v0.41.0"
NODE_MAJOR="24"
ANDROID_SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
ANDROID_API_LEVELS="${ANDROID_API_LEVELS:-34 36}"
ANDROID_BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-34.0.0 36.0.0}"

log()  { printf '\n\033[1;32m[ScrollSlayer setup]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[WARNING]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || die "This script is for Ubuntu/Linux Mint."
[[ "$(uname -m)" == "x86_64" ]] || warn "This script was prepared for x86_64; review package/download compatibility."

if ! command -v apt-get >/dev/null 2>&1; then
  die "apt-get was not found. This script supports Ubuntu/Linux Mint."
fi

if ! command -v sudo >/dev/null 2>&1; then
  die "sudo is required to install Ubuntu system packages."
fi

log "Installing required Ubuntu packages (this does not upgrade the whole OS)."
sudo apt-get update
sudo apt-get install -y \
  openjdk-17-jdk \
  curl wget unzip zip git ca-certificates \
  adb android-sdk-platform-tools-common \
  file

# Detect Java 17 and derive JAVA_HOME from javac.
if ! command -v javac >/dev/null 2>&1 || ! javac -version 2>&1 | grep -q '17'; then
  die "Java 17 compiler was not found after package installation."
fi

JAVAC_REAL="$(readlink -f "$(command -v javac)")"
JAVA_HOME_DETECTED="$(dirname "$(dirname "$JAVAC_REAL")")"
export JAVA_HOME="$JAVA_HOME_DETECTED"

log "Configuring NVM and Node.js ${NODE_MAJOR}."
export NVM_DIR="$HOME/.nvm"
if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  mkdir -p "$NVM_DIR"
  export PROFILE="$HOME/.zshrc"
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
  unset PROFILE
fi

if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  die "NVM installation did not create $NVM_DIR/nvm.sh"
fi

# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"
nvm install "$NODE_MAJOR"
nvm alias default "$NODE_MAJOR"
nvm use "$NODE_MAJOR" >/dev/null

log "Preparing Android SDK at: $ANDROID_SDK"
mkdir -p "$ANDROID_SDK"

SDKMANAGER="$ANDROID_SDK/cmdline-tools/latest/bin/sdkmanager"

if [[ ! -x "$SDKMANAGER" ]]; then
  log "Android SDK command-line tools are missing; downloading Google's official Linux tools."
  BUILD="15859902"
  ZIP_NAME="commandlinetools-linux-${BUILD}_latest.zip"
  URL="https://dl.google.com/android/repository/${ZIP_NAME}"
  EXPECTED_SHA256="4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583"
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR:-}"' EXIT

  curl -fL --retry 3 "$URL" -o "$TMP_DIR/$ZIP_NAME"
  ACTUAL_SHA256="$(sha256sum "$TMP_DIR/$ZIP_NAME" | awk '{print $1}')"
  [[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || die "Android command-line tools checksum did not match. Download removed; refusing to install."

  unzip -q "$TMP_DIR/$ZIP_NAME" -d "$TMP_DIR/unpacked"
  mkdir -p "$ANDROID_SDK/cmdline-tools"
  if [[ -e "$ANDROID_SDK/cmdline-tools/latest" ]]; then
    die "A cmdline-tools/latest directory exists but sdkmanager was not executable. Inspect it manually; nothing was overwritten."
  fi
  mv "$TMP_DIR/unpacked/cmdline-tools" "$ANDROID_SDK/cmdline-tools/latest"
fi

[[ -x "$SDKMANAGER" ]] || die "sdkmanager is still unavailable at $SDKMANAGER"

# Install both the existing baseline (API 34) and a newer stable SDK (API 36).
# These packages are safe to install alongside other SDK versions.
SDK_PACKAGES=("platform-tools")
for api in $ANDROID_API_LEVELS; do
  SDK_PACKAGES+=("platforms;android-${api}")
done
for build in $ANDROID_BUILD_TOOLS; do
  SDK_PACKAGES+=("build-tools;${build}")
done

log "Accepting Android SDK licenses."
set +o pipefail
yes | "$SDKMANAGER" --sdk_root="$ANDROID_SDK" --licenses
set -o pipefail

log "Installing Android SDK packages: ${SDK_PACKAGES[*]}"
"$SDKMANAGER" --sdk_root="$ANDROID_SDK" "${SDK_PACKAGES[@]}"

# Add the current user to plugdev when the group exists; user must log out/in for it to apply.
if getent group plugdev >/dev/null 2>&1; then
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx plugdev; then
    log "Adding $USER to plugdev for USB debugging permissions."
    sudo usermod -aG plugdev "$USER"
    warn "Group membership takes effect after you log out and back in (or reboot)."
  else
    log "$USER is already a member of plugdev."
  fi
else
  warn "plugdev group was not found; Android USB udev rules were installed, but USB permissions may need manual review."
fi

# Configure the active shell startup file without duplicating the block.
SHELL_NAME="$(basename "${SHELL:-bash}")"
if [[ "$SHELL_NAME" == "zsh" ]]; then
  RC_FILE="$HOME/.zshrc"
else
  RC_FILE="$HOME/.bashrc"
fi

BEGIN_MARKER="# >>> ScrollSlayer Android development environment >>>"
END_MARKER="# <<< ScrollSlayer Android development environment <<<"
touch "$RC_FILE"
if ! grep -Fq "$BEGIN_MARKER" "$RC_FILE"; then
  {
    printf '\n%s\n' "$BEGIN_MARKER"
    printf 'export JAVA_HOME="%s"\n' "$JAVA_HOME_DETECTED"
    printf 'export ANDROID_HOME="%s"\n' "$ANDROID_SDK"
    printf 'export ANDROID_SDK_ROOT="$ANDROID_HOME"\n'
    printf 'export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"\n'
    printf '%s\n' "$END_MARKER"
  } >> "$RC_FILE"
else
  log "Android environment block already exists in $RC_FILE; leaving it unchanged."
fi

# VS Code extensions. The JetBrains Kotlin extension is currently alpha.
if command -v code >/dev/null 2>&1; then
  log "Installing/updating VS Code Android/Java/Kotlin extensions."
  EXTENSIONS=(
    "vscjava.vscode-java-pack"
    "vscjava.vscode-gradle"
    "redhat.vscode-xml"
    "JetBrains.kotlin-server"
    "qwtel.sqlite-viewer"
  )
  for extension in "${EXTENSIONS[@]}"; do
    code --install-extension "$extension" --force || warn "Could not install VS Code extension: $extension"
  done
else
  warn "VS Code command 'code' was not found. Install extensions later from VS Code's Extensions panel."
fi

# Ensure the current process can use SDK tools and Java.
export ANDROID_HOME="$ANDROID_SDK"
export ANDROID_SDK_ROOT="$ANDROID_SDK"
export PATH="$JAVA_HOME/bin:$ANDROID_SDK/bin:$ANDROID_SDK/cmdline-tools/latest/bin:$ANDROID_SDK/platform-tools:$PATH"

log "Verifying installed toolchain."
java -version
javac -version
node -v
npm -v
"$SDKMANAGER" --version
adb version

log "Installed Android SDK packages:"
"$SDKMANAGER" --sdk_root="$ANDROID_SDK" --list_installed

log "Checking connected Android devices (connect/unlock the phone if none appear)."
adb devices -l || true

cat <<EOF

============================================================
ScrollSlayer Android development environment setup finished
============================================================

SDK location: $ANDROID_SDK
Java home:    $JAVA_HOME
Shell config: $RC_FILE

Next:
  1. Close and reopen your terminal, or run: source "$RC_FILE"
  2. Check: java -version && node -v && npm -v
  3. Check phone: adb devices -l

Notes:
  - This script does not install Android Studio or an emulator.
  - It does not install a global Gradle; Android projects should use ./gradlew.
  - Kotlin compilation is normally provided by the project's Gradle/Kotlin plugin.
  - The VS Code Kotlin extension is an editor tool, not the Kotlin compiler.
  - It does not delete projects, APKs, SDK versions, or existing user files.
  - Re-running this script is intended to be safe and will skip existing NVM/SDK tools.
============================================================
EOF
