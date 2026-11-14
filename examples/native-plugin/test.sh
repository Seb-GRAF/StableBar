#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
sdk_header="$script_dir/../../Sources/NativeWidgetPluginABI/include/StableBarNativeWidgetPlugin.h"
staging="$(mktemp -d "${TMPDIR:-/tmp}/stablebar-native-demo-test.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

"$script_dir/build.sh" "$staging/output"
swiftc \
	-parse-as-library \
	-swift-version 5 \
	-target "$(uname -m)-apple-macos14.0" \
	-sdk "$(xcrun --sdk macosx --show-sdk-path)" \
	-import-objc-header "$sdk_header" \
	-framework AppKit \
	"$script_dir/TestHost.swift" \
	-o "$staging/native-plugin-test-host"
"$staging/native-plugin-test-host" "$staging/output/StableBarNativeDemo.bundle"
