#!/bin/bash

set -euo pipefail

version="${1:-1.0.0}"
app_path="${APP_PATH:-build/DerivedData/Build/Products/Release/Vibelimit.app}"
output_dir="${OUTPUT_DIR:-build/release}"
volume_name="Vibelimit"
dmg_path="${output_dir}/Vibelimit-${version}.dmg"

if [[ ! -d "${app_path}" ]]; then
    echo "App bundle not found at ${app_path}" >&2
    exit 1
fi

mkdir -p "${output_dir}"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibelimit-release.XXXXXX")"

cleanup() {
    rm -rf "${staging_dir}"
}
trap cleanup EXIT

ditto "${app_path}" "${staging_dir}/Vibelimit.app"
ln -s /Applications "${staging_dir}/Applications"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "${SIGNING_IDENTITY}" \
        "${staging_dir}/Vibelimit.app"
    codesign --verify --deep --strict --verbose=2 "${staging_dir}/Vibelimit.app"
else
    codesign --force --deep --sign - "${staging_dir}/Vibelimit.app"
    echo "Created an ad hoc signed app. Downloads will require manual Gatekeeper approval."
fi

hdiutil create \
    -volname "${volume_name}" \
    -srcfolder "${staging_dir}" \
    -ov \
    -format UDZO \
    "${dmg_path}"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "${SIGNING_IDENTITY}" "${dmg_path}"
    codesign --verify --verbose=2 "${dmg_path}"
fi

shasum -a 256 "${dmg_path}" > "${dmg_path}.sha256"
echo "Created ${dmg_path}"
