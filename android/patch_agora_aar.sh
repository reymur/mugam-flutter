#!/usr/bin/env bash
set -euo pipefail

# Regenerates android/local_repo/ — a local Maven repository containing a
# single patched artifact: io.agora.rtc:agora-special-full:4.5.3.70 with
# its AndroidManifest.xml package renamed from "io.agora.rtc" to
# "io.agora.rtc.specialfull".
#
# WHY: agora_rtc_engine 6.5.4 pulls in two native AARs — io.agora.rtc:
# iris-rtc and io.agora.rtc:agora-special-full — that both declare the
# IDENTICAL manifest package "io.agora.rtc". AGP 9's manifest merger
# enforces unique namespaces across all resolved artifacts and hard-fails
# the build on this exact collision (:app:processDebugMainManifest,
# "Namespace io.agora.rtc is used in multiple modules").
#
# Neither AAR can be excluded — both are legitimately required (iris-rtc
# is the Flutter<->native bridge layer, agora-special-full is the native
# RTC engine binary itself). agora-special-full has zero resources
# (confirmed: no res/ folder, empty R.txt), so a manifest-only package
# rename is safe — nothing else in the AAR references its own R class.
#
# This script downloads the ORIGINAL unpatched AAR directly from Maven
# Central (not the Gradle cache, so it works on a clean checkout with an
# empty ~/.gradle before any build has ever run) and produces a local
# Maven repo entry at the exact same coordinates, which
# android/build.gradle.kts's repositories block resolves BEFORE ever
# reaching Maven Central for this one artifact.
#
# Not committed to git — the original AAR alone is ~139MB, over GitHub's
# 100MB hard limit. Re-run this script after `flutter clean` / a fresh
# checkout, before the first build.

GROUP_PATH="io/agora/rtc"
ARTIFACT="agora-special-full"
VERSION="4.5.3.70"
MAVEN_URL="https://repo1.maven.org/maven2/${GROUP_PATH}/${ARTIFACT}/${VERSION}/${ARTIFACT}-${VERSION}.aar"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

OUT_DIR="${SCRIPT_DIR}/local_repo/${GROUP_PATH}/${ARTIFACT}/${VERSION}"
OUT_AAR="${OUT_DIR}/${ARTIFACT}-${VERSION}.aar"
OUT_POM="${OUT_DIR}/${ARTIFACT}-${VERSION}.pom"

echo "Downloading original AAR from Maven Central..."
curl -fL -o "${WORK_DIR}/original.aar" "$MAVEN_URL"

echo "Extracting..."
mkdir -p "${WORK_DIR}/extracted"
unzip -q "${WORK_DIR}/original.aar" -d "${WORK_DIR}/extracted"

echo "Patching AndroidManifest.xml package..."
sed -i.bak 's/package="io.agora.rtc"/package="io.agora.rtc.specialfull"/' \
  "${WORK_DIR}/extracted/AndroidManifest.xml"
rm -f "${WORK_DIR}/extracted/AndroidManifest.xml.bak"

if ! grep -q 'package="io.agora.rtc.specialfull"' "${WORK_DIR}/extracted/AndroidManifest.xml"; then
  echo "ERROR: patch did not apply — manifest package attribute not found or already different." >&2
  exit 1
fi

echo "Repackaging..."
mkdir -p "$OUT_DIR"
rm -f "$OUT_AAR"
( cd "${WORK_DIR}/extracted" && zip -qr "$OUT_AAR" . -x ".*" )

cat > "$OUT_POM" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>io.agora.rtc</groupId>
  <artifactId>${ARTIFACT}</artifactId>
  <version>${VERSION}</version>
  <packaging>aar</packaging>
</project>
EOF

echo "Done: ${OUT_AAR}"
