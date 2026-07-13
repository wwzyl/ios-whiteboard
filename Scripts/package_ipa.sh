#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
IPA_DIR="${BUILD_DIR}/ipa"
APP_PATH="${DERIVED_DATA}/Build/Products/Release-iphoneos/CBrainIOS.app"
IPA_PATH="${IPA_DIR}/CBrainIOS.ipa"
LOG_PATH="${BUILD_DIR}/xcodebuild.log"

rm -rf "${BUILD_DIR}"
mkdir -p "${IPA_DIR}"

xcodebuild \
  -project "${ROOT_DIR}/CBrainIOS.xcodeproj" \
  -scheme CBrainIOS \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  clean build 2>&1 | tee "${LOG_PATH}"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "App bundle not found: ${APP_PATH}" >&2
  exit 1
fi

WORK_DIR="${BUILD_DIR}/PayloadWork"
mkdir -p "${WORK_DIR}/Payload"
cp -R "${APP_PATH}" "${WORK_DIR}/Payload/"

(
  cd "${WORK_DIR}"
  /usr/bin/zip -qry "${IPA_PATH}" Payload
)

echo "${IPA_PATH}"
