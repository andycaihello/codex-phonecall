#!/bin/sh
set -eu
permission_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror \
  "$permission_dir/pcm-permission-launcher.m" -framework Foundation -framework AppKit \
  -o "$permission_dir/pcm-permission-launcher"
codesign --force --sign - "$permission_dir/pcm-permission-launcher"
codesign --verify --strict "$permission_dir/pcm-permission-launcher"
printf '%s\n' "$permission_dir/pcm-permission-launcher"
