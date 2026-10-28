#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")" && pwd)"
task_deveco="${PHONEBRIDGE_DEVECO_CONTENTS:-/Applications/DevEco-Studio.app/Contents}"
cd "$task_root"
export DEVECO_SDK_HOME="$task_deveco/sdk"
export JAVA_HOME="$task_deveco/jbr/Contents/Home"
export PATH="$task_deveco/tools/node/bin:$task_deveco/tools/ohpm/bin:$PATH"
"$task_deveco/tools/node/bin/node" "$task_deveco/tools/hvigor/bin/hvigorw.js" --mode module -p product=default -p module=entry@default assembleHap --no-daemon
