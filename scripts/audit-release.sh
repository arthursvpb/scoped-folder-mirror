#!/bin/sh
set -eu

for required in xcodebuild xcrun codesign; do
    command -v "$required" >/dev/null
done

legacy_type_pattern='SyncI''CloudToUSB'
legacy_repo_pattern='sync-i''cloud-to-usb'
private_app_pattern='en''pass'
local_home_pattern='/''Users/'
file_url_pattern='file:'"///"
if rg -n -i \
    "${legacy_type_pattern}|${legacy_repo_pattern}|${private_app_pattern}|${local_home_pattern}|${file_url_pattern}" \
    --glob '!ScopedFolderMirror.xcodeproj/**' \
    --glob '!scripts/audit-release.sh' \
    --glob '!scripts/package-preview.sh' \
    --glob '!.git/**' \
    --glob '!.build/**' \
    --glob '!build/**' \
    --glob '!dist/**' .; then
    echo "Public-source string scan failed" >&2
    exit 1
fi

if rg -n 'Process\(|/bin/(sh|bash|zsh)|osascript|NSAppleScript|SMJobBless|LaunchAgent|LaunchDaemon' ScopedFolderMirror; then
    echo "Runtime helper and shell denylist failed" >&2
    exit 1
fi

entitlements=Configuration/ScopedFolderMirror.entitlements
entitlement_count=$(grep -c '<key>' "$entitlements" || true)
if [ "$entitlement_count" -ne 3 ]; then
    echo "Entitlement allowlist must contain exactly three keys" >&2
    exit 1
fi
for allowed in \
    com.apple.security.app-sandbox \
    com.apple.security.files.bookmarks.app-scope \
    com.apple.security.files.user-selected.read-write; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$allowed" "$entitlements")
    if [ "$value" != true ]; then
        echo "Required entitlement is unavailable: $allowed" >&2
        exit 1
    fi
done

if command -v gitleaks >/dev/null; then
    gitleaks dir --no-banner --redact .
else
    echo "gitleaks is not installed" >&2
    exit 1
fi

echo "Release policy audit passed"
