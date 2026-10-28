#!/bin/sh
set -eu
bt_control_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
xcrun clang++ -std=c++17 -fobjc-arc -O2 -Wall -Wextra -Werror \
  "$bt_control_dir/bluetooth-call-control.mm" -framework Foundation -framework IOBluetooth \
  -o "$bt_control_dir/bluetooth-call-control"
codesign --force --sign - "$bt_control_dir/bluetooth-call-control"
codesign --verify --strict "$bt_control_dir/bluetooth-call-control"
printf '%s\n' "$bt_control_dir/bluetooth-call-control"
