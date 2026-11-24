#!/bin/bash
# Render the embedded shader offscreen on the Mac, including the drawable outside the visible rect.
set -eu -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
src=tweak/Sources/Redesigned/Kit/SGRFluidGPU.m
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
shader() { sed -n '/^static NSString \*const kShader =/,/^"}\\n";/p'; }
shader < "${FLUID_SOURCE:-$root/$src}" > "$work/current.inc"
git -C "$root" show "0493378e:$src" | shader | sed 's/\*const kShader =/*const referenceShader =/' > "$work/reference.inc"
xcrun clang -fobjc-arc -framework Metal -framework Foundation -I"$work" "$here/fluid-fragment-check.m" -o "$work/check"
"$work/check"
