#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 2 || ! -f "$1" ]]; then
  echo "Usage: packaging/flatpak/build.sh path/to/feud-hall.deb output.flatpak" >&2
  exit 2
fi
manifest_dir=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
trap 'trap - EXIT; python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$scratch"' EXIT
app_id=io.github.adsouza.FeudHall

dpkg-deb --extract "$1" "$scratch/deb"
install -m755 "$scratch/deb/usr/bin/feud-hall" "$scratch/feud-hall"
install -m644 "$scratch/deb/usr/share/icons/hicolor/512x512/apps/feud-hall.png" "$scratch/icon.png"
cp "$manifest_dir/$app_id."{desktop,metainfo.xml,yml} "$scratch/"

flatpak-builder --user --disable-download --repo="$scratch/repo" "$scratch/build" "$scratch/$app_id.yml"
flatpak build-bundle --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo \
  "$scratch/repo" "$2" "$app_id"
