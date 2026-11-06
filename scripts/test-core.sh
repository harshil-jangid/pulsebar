#!/usr/bin/env bash
# Run PulseBarCore unit tests with SwiftPM.
# Works with full Xcode, and also with only the Command Line Tools, whose
# Swift Testing framework lives outside SwiftPM's default search paths.
set -euo pipefail
cd "$(dirname "$0")/../Packages/PulseBarCore"

extra=()
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  D=/Library/Developer/CommandLineTools/Library/Developer
  extra=(-Xswiftc -F -Xswiftc "$D/Frameworks"
         -Xlinker -F -Xlinker "$D/Frameworks"
         -Xlinker -rpath -Xlinker "$D/Frameworks"
         -Xlinker -rpath -Xlinker "$D/usr/lib")
fi
swift test ${extra[@]+"${extra[@]}"} "$@"
