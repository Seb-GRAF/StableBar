#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
sdk_header="$script_dir/../../Sources/NativeWidgetPluginABI/include/StableBarNativeWidgetPlugin.h"
output_dir="${1:-$script_dir/build}"
staging="$(mktemp -d "${TMPDIR:-/tmp}/stablebar-native-demo.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
	swiftc \
		-swift-version 5 \
		-target "$arch-apple-macos14.0" \
		-sdk "$sdk" \
		-module-name StableBarNativeDemo \
		-import-objc-header "$sdk_header" \
		-emit-library \
		-Xlinker -bundle \
		-framework AppKit \
		-framework SwiftUI \
		"$script_dir/Plugin.swift" \
		-o "$staging/StableBarNativeDemo-$arch"
done

bundle="$output_dir/StableBarNativeDemo.bundle"
mkdir -p "$bundle/Contents/MacOS"
cp "$script_dir/Info.plist" "$bundle/Contents/Info.plist"
lipo -create "$staging/StableBarNativeDemo-arm64" "$staging/StableBarNativeDemo-x86_64" \
	-output "$bundle/Contents/MacOS/StableBarNativeDemo"
codesign --force --sign - "$bundle"
