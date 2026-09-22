#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${ROOT}/dist"
APP="${DIST}/ClaudeGauge.app"
BIN_NAME="ClaudeGauge"
PLIST_SRC="${ROOT}/Resources/Info.plist"

cd "${ROOT}"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/${BIN_NAME}"
if [[ ! -x "${BIN}" ]]; then
  echo "error: release binary not found at ${BIN}" >&2
  exit 1
fi

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BIN}" "${APP}/Contents/MacOS/${BIN_NAME}"
chmod +x "${APP}/Contents/MacOS/${BIN_NAME}"
cp "${PLIST_SRC}" "${APP}/Contents/Info.plist"

# Ad-hoc sign for local run (no Developer ID / notarization).
codesign --force --deep --sign - "${APP}"

echo "Built: ${APP}"
