#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/intel-compat.sh <App.app | disk-image.dmg>
  scripts/intel-compat.sh --build-negs

Audit a macOS app/disk image for x86_64 executable code, or build this Negs
checkout as an Intel-only app. An ARM-only binary cannot be translated into
x86_64 machine code; rebuilding requires the original source code.
EOF
}

if [[ "${1:-}" == "--build-negs" ]]; then
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    cd "$repo_root"
    MACOS_ARCHS=x86_64 bash scripts/package_macos_app.sh
    exit
fi

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
input="$1"
[[ -e "$input" ]] || { echo "Input not found: $input" >&2; exit 2; }

mountpoint=""
cleanup() {
    if [[ -n "$mountpoint" ]]; then
        hdiutil detach "$mountpoint" -quiet || true
        rmdir "$mountpoint" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [[ "$input" == *.dmg ]]; then
    mountpoint="$(mktemp -d "${TMPDIR:-/tmp}/intel-compat.XXXXXX")"
    hdiutil attach "$input" -readonly -nobrowse -mountpoint "$mountpoint" >/dev/null
    app="$(find "$mountpoint" -type d -name '*.app' -prune -print -quit)"
    [[ -n "$app" ]] || { echo "No .app bundle found in disk image." >&2; exit 2; }
elif [[ -d "$input" && "$input" == *.app ]]; then
    app="$input"
else
    echo "Provide a .app bundle or .dmg disk image." >&2
    exit 2
fi

command -v lipo >/dev/null || { echo "lipo is required (install Apple's Command Line Tools)." >&2; exit 2; }
count=0
missing=0
echo "Inspecting: $app"
while IFS= read -r -d '' candidate; do
    if ! file -b "$candidate" | grep -q 'Mach-O'; then continue; fi
    count=$((count + 1))
    archs="$(lipo -archs "$candidate" 2>/dev/null || true)"
    if [[ " $archs " == *" x86_64 "* ]]; then
        printf 'INTEL OK  %-24s %s\n' "$archs" "${candidate#"$app"/}"
    else
        missing=$((missing + 1))
        printf 'NO INTEL  %-24s %s\n' "${archs:-unknown} (ARM-only or unreadable)" "${candidate#"$app"/}"
    fi
done < <(find "$app/Contents" -type f -print0)

echo
if [[ $count -eq 0 ]]; then
    echo "No Mach-O files found; this may not be a conventional native macOS app."
    exit 2
elif [[ $missing -eq 0 ]]; then
    echo "Intel code is present in all $count Mach-O files. This is an architecture check, not a launch or OS-version guarantee."
else
    echo "$missing of $count Mach-O files lack x86_64. This bundle cannot run on Intel as supplied."
    echo "There is no general ARM-to-Intel app converter. Obtain an Intel/universal release or rebuild from source."
    exit 1
fi
