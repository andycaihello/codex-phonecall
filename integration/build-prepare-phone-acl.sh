#!/bin/sh
set -eu
acl_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
xcrun clang -std=c11 -fobjc-arc -O2 -Wall -Wextra -Werror \
  "$acl_dir/prepare-phone-acl.m" -framework Foundation -framework IOBluetooth \
  -o "$acl_dir/prepare-phone-acl"
codesign --force --sign - "$acl_dir/prepare-phone-acl"
codesign --verify --strict "$acl_dir/prepare-phone-acl"
printf '%s\n' "$acl_dir/prepare-phone-acl"
