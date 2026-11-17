#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SRC=${SRC:-"$HERE/../../tweak/Sources"}
OUT=${OUT:-"$HERE/build-readiness"}
mkdir -p "$OUT"
xcrun clang -fobjc-arc -fmodules -DSGWG_TESTING -mmacosx-version-min=14.0 -Wall \
    -I"$SRC" "$HERE/readiness.m" -framework Foundation -framework Network -framework Security \
    -framework CoreFoundation -o "$OUT/readiness"
SGWG_TEST_ENABLED=0 "$OUT/readiness"
