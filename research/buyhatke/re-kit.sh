#!/usr/bin/env bash
# Reverse-engineering kit for the BuyHatke browser extension, Android app and website,
# driven by REA (https://github.com/morluto/rea). Run it on your own machine: it needs
# network access to the Chrome Web Store and buyhatke.com.
#
# Usage:
#   ./re-kit.sh extension            # download + unpack the Chrome extension, run REA on it
#   ./re-kit.sh apk /path/app.apk    # inspect an APK you pulled from your own phone
#   ./re-kit.sh har /path/file.har   # inspect a DevTools HAR saved while a price chart loaded
#   ./re-kit.sh grep                 # list hosts/endpoints referenced by the unpacked extension
set -euo pipefail

EXT_ID="ojplmecpdpgccookcobabopnaifgidhf"   # "Buyhatke: Price History & Tracker, Spend Lens"
WORK="${WORK:-$PWD/buyhatke-work}"
REA="npx -y rea-agents@latest"
mkdir -p "$WORK"

case "${1:-}" in
  extension)
    crx="$WORK/buyhatke.crx"
    curl -fL -o "$crx" \
      "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=131.0&acceptformat=crx2,crx3&x=id%3D${EXT_ID}%26uc"
    rm -rf "$WORK/extension" && mkdir -p "$WORK/extension"
    # A CRX is a zip with a signed header in front; unzip skips the header (exit 1 = warning only).
    unzip -q -o "$crx" -d "$WORK/extension" || [ $? -eq 1 ]
    $REA analyze-javascript-application "$WORK/extension" --format json > "$WORK/extension-evidence.json"
    echo "Evidence: $WORK/extension-evidence.json"
    echo "Next: ./re-kit.sh grep, then ask your agent (with REA connected) to trace the price-graph"
    echo "      and price-alert features from the seeds that grep prints."
    ;;
  apk)
    $REA inspect-android-package "${2:?path to APK}" --format json > "$WORK/apk-evidence.json"
    echo "Evidence: $WORK/apk-evidence.json"
    ;;
  har)
    $REA inspect-web-network-capture "${2:?absolute path to HAR}" har --format json > "$WORK/har-evidence.json"
    echo "Evidence: $WORK/har-evidence.json"
    ;;
  grep)
    # Fast seed list for feature tracing: every BuyHatke host/path and chart/alert keyword.
    grep -rhoE "https?://[a-zA-Z0-9.-]*buyhatke\.com[a-zA-Z0-9/._?=&%-]*" "$WORK/extension" | sort | uniq -c | sort -rn
    grep -rlE "graph|chart|priceHistory|alert|wishlist|loot|predict" "$WORK/extension" | head -50
    ;;
  *)
    sed -n 2,11p "$0"; exit 1 ;;
esac
