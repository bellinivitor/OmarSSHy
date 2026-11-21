#!/bin/bash
set -euo pipefail

project=$(cd "$(dirname "$0")/.." && pwd)
destination=${1:-"$project/dist"}
if [[ $# -gt 0 ]]; then shift; fi
mkdir -p "$destination"
destination=$(cd "$destination" && pwd)
if [[ -e "$destination/OmarSSHy.app" ]]; then
    printf 'Já existe um OmarSSHy.app em %s. Escolha outra pasta de destino.\n' "$destination" >&2
    exit 1
fi

cd "$project"
configuration=${OMARSSHY_BUILD_CONFIGURATION:-release}
swift build --configuration "$configuration" --product OmarSSHy "$@"
binary_dir=$(swift build --configuration "$configuration" --show-bin-path "$@")

staging=$(mktemp -d "${TMPDIR:-/tmp}/omarsshy.XXXXXXXX")
trap 'test ! -d "$staging" || rm -r -- "$staging"' EXIT
bundle="$staging/OmarSSHy.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -m 755 "$binary_dir/OmarSSHy" "$bundle/Contents/MacOS/OmarSSHy"
cp Scripts/Info.plist "$bundle/Contents/Info.plist"
printf 'APPL????' > "$bundle/Contents/PkgInfo"

scratch="$binary_dir"
while [[ "$scratch" != / && ! -d "$scratch/checkouts/SwiftTerm" ]]; do
    scratch=$(dirname "$scratch")
done
if [[ ! -f "$scratch/checkouts/SwiftTerm/LICENSE" ]]; then
    printf 'Licença do SwiftTerm ausente no checkout do SwiftPM.\n' >&2
    exit 1
fi
cp "$scratch/checkouts/SwiftTerm/LICENSE" "$bundle/Contents/Resources/SwiftTerm-LICENSE.txt"

for resource in "$binary_dir"/*.bundle; do
    if [[ -d "$resource" ]]; then
        ditto "$resource" "$bundle/Contents/Resources/$(basename "$resource")"
    fi
done

swift -module-cache-path "$binary_dir/ModuleCache.noindex" Scripts/make-icon.swift "$bundle/Contents/Resources/OmarSSHy.icns"

codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
mv "$bundle" "$destination/OmarSSHy.app"
printf '%s\n' "$destination/OmarSSHy.app"
