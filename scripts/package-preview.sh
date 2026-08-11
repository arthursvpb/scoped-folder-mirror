#!/bin/sh
set -eu

for required in codesign hdiutil lipo otool rg xcodebuild; do
    command -v "$required" >/dev/null
done

version=${1:-}
architecture=${2:-}

if [ -z "$version" ] || [ -z "$architecture" ]; then
    echo "Usage: $0 VERSION arm64|x86_64" >&2
    exit 64
fi

case "$architecture" in
    arm64|x86_64) ;;
    *) echo "Unsupported architecture: $architecture" >&2; exit 64 ;;
esac

build_root="${PWD}/build/${architecture}"
distribution_root="${PWD}/dist"
image_root=$(mktemp -d)
mounted_root=$(mktemp -d)
artifact="${distribution_root}/Scoped-Folder-Mirror-${version}-macOS-${architecture}.dmg"

cleanup() {
    hdiutil detach "$mounted_root" >/dev/null 2>&1 || true
    rmdir "$mounted_root" >/dev/null 2>&1 || true
    rm -rf "$image_root"
}
trap cleanup EXIT INT TERM

xcodebuild \
    -project ScopedFolderMirror.xcodeproj \
    -scheme ScopedFolderMirror \
    -configuration Release \
    -destination "platform=macOS,arch=${architecture}" \
    -derivedDataPath "$build_root" \
    ARCHS="$architecture" \
    ONLY_ACTIVE_ARCH=YES \
    build

mkdir -p "$distribution_root"
cp -R "$build_root/Build/Products/Release/ScopedFolderMirror.app" "$image_root/Scoped Folder Mirror.app"
ln -s /Applications "$image_root/Applications"
rm -f "$artifact"
hdiutil create -quiet -volname "Scoped Folder Mirror" -srcfolder "$image_root" -format UDZO "$artifact"

hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mounted_root" "$artifact"
test -d "$mounted_root/Scoped Folder Mirror.app"
binary="$mounted_root/Scoped Folder Mirror.app/Contents/MacOS/ScopedFolderMirror"
lipo "$binary" -verify_arch "$architecture"
codesign --verify --deep --strict "$mounted_root/Scoped Folder Mirror.app"
signed_entitlements=$(codesign -d --entitlements :- "$mounted_root/Scoped Folder Mirror.app" 2>/dev/null)
signed_entitlement_count=$(printf '%s\n' "$signed_entitlements" | grep -o '<true/>' | wc -l | tr -d ' ')
test "$signed_entitlement_count" -eq 3
for allowed in \
    com.apple.security.app-sandbox \
    com.apple.security.files.bookmarks.app-scope \
    com.apple.security.files.user-selected.read-write; do
    printf '%s\n' "$signed_entitlements" | grep -F "<key>$allowed</key>" >/dev/null
done
local_home_pattern='/''Users/'
file_url_pattern='file:'"///"
legacy_type_pattern='SyncI''CloudToUSB'
legacy_repo_pattern='sync-i''cloud-to-usb'
private_app_pattern='en''pass'
private_cloud_pattern='i''cloud'
private_session_pattern='019fed''bf'
private_profile_pattern='profiles/core/''repos'
private_codex_pattern='\\.co''dex'
private_yui_pattern='\\.y''ui'
if otool -l "$binary" | rg -q '__llvm_(prf|cov)' || \
    rg -a -q 'default\.profraw|LLVM_PROFILE_FILE' "$binary"; then
    echo "Release artifact contains coverage instrumentation" >&2
    exit 1
fi
if rg -a -q -i \
    "${legacy_type_pattern}|${legacy_repo_pattern}|${private_app_pattern}|${private_cloud_pattern}|${local_home_pattern}|${file_url_pattern}|@users\\.noreply\\.github\\.com|${private_session_pattern}|${private_profile_pattern}|${private_codex_pattern}|${private_yui_pattern}" \
    "$mounted_root/Scoped Folder Mirror.app"; then
    echo "Artifact string scan failed" >&2
    exit 1
fi
hdiutil detach -quiet "$mounted_root"

(cd "$distribution_root" && shasum -a 256 "$(basename "$artifact")" > "$(basename "$artifact").sha256")
(cd "$distribution_root" && shasum -a 256 -c "$(basename "$artifact").sha256")
(cd "$distribution_root" && shasum -a 256 Scoped-Folder-Mirror-"$version"-macOS-*.dmg > SHA256SUMS)
(cd "$distribution_root" && shasum -a 256 -c SHA256SUMS)
echo "$artifact"
