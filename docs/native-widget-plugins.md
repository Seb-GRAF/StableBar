# Native widget plugins

This document describes the current API v1 contract and the demo in `examples/native-plugin`.
The loader and package checks exist, but StableBar does not yet create plugin instances from bar widgets.
The demo harness loads a bundle directly. It does not test the complete StableBar install, consent, and display flow.

## Package format

A native plugin is a widget package. Its `package.json` keeps the regular package fields and adds `nativeBundle`:

```json
{
  "id": "org.stablebar.example.native-demo",
  "name": "StableBar Native Plugin Demo",
  "version": "1.0.0",
  "kind": "widgets",
  "entry": "config.json",
  "nativeBundle": "build/StableBarNativeDemo.bundle"
}
```

`nativeBundle` is optional. When present, it must name a `.bundle` directory inside the package. The manifest must use `kind: "widgets"`.
The package inspector rejects paths outside the package and checks the bundle metadata and signature without loading its code.

The bundle `Info.plist` must contain:

| Key | Requirement |
| --- | --- |
| `CFBundlePackageType` | `BNDL` |
| `CFBundleIdentifier` | Must equal `package.json` `id` |
| `CFBundleShortVersionString` | Must equal `package.json` `version` |
| `CFBundleExecutable` | Non-empty executable name |
| `NSPrincipalClass` | Non-empty Objective-C class name |
| `StableBarNativeWidgetPluginAPIMajor` | Integer `1` |

The code signature identifier must equal `CFBundleIdentifier`. The principal class must inherit from `NSObject`, implement `StableBarNativeWidgetPlugin`, and report the same API major in `apiVersion`.

The widget entry selects the package by ID:

```json
{
  "widgets": [
    {
      "id": "native-demo",
      "type": "nativePlugin",
      "plugin": "org.stablebar.example.native-demo",
      "position": "right"
    }
  ]
}
```

The `plugin` value must equal the package ID. The example files are `examples/native-plugin/package.json` and `examples/native-plugin/config.json`.

## Build the example

The example uses the shared Objective-C header at `Sources/NativeWidgetPluginABI/include/StableBarNativeWidgetPlugin.h`.
Both StableBar and the plugin compile against that header. The plugin does not import a StableBar Swift module.

Run the standalone bundle harness:

```sh
examples/native-plugin/test.sh
```

The script compiles a universal `arm64` and `x86_64` bundle in a temporary directory, builds a small host, and loads the bundle in that host.
It checks configuration, lifecycle methods, an event callback, settings callbacks, the widget view, and popup creation.
The script removes its temporary output when it exits.

To build the bundle into the example package tree, run:

```sh
examples/native-plugin/build.sh
```

This writes `examples/native-plugin/build/StableBarNativeDemo.bundle`, which matches the manifest's `nativeBundle` path.
Pass another output directory to keep the bundle elsewhere:

```sh
examples/native-plugin/build.sh /tmp/native-plugin-output
```

The example script signs the bundle with an ad-hoc signature (`codesign --sign -`). This is enough for its direct test host.
The current StableBar signature verifier rejects ad-hoc signatures. The example bundle therefore cannot pass StableBar's current preflight.
Use a real Developer ID signing identity for an installable candidate. The signature must include a Team ID and a CMS signature.

## API v1

The shared header defines Objective-C protocols. The host imports the plugin through the Clang target `NativeWidgetPluginABI`.
The plugin implements the protocol in Swift or Objective-C. Keep the Objective-C selectors and data types compatible with the shared header.

Required plugin methods:

```objc
@property(nonatomic, readonly) NSInteger apiVersion;
- (NSView *)makeWidgetView;
- (NSView *)makePopupView;
- (void)start;
- (void)stop;
```

The host calls these methods on the main actor. `makeWidgetView` returns the view for the bar item.
`makePopupView` returns the view for a popup. The loader instance creates it only when its `makePopupView()` method is called.

The host protocol provides these callbacks:

```objc
- (void)requestPopup;
- (void)saveSettings:(NSDictionary<NSString *, id> *)settings;
```

The plugin may implement these optional methods:

```objc
- (void)configureWithHost:(id<StableBarNativeWidgetHost>)host
                 settings:(NSDictionary<NSString *, id> *)settings;
- (void)settingsDidChange:(NSDictionary<NSString *, id> *)settings;
- (void)stableBarDidReceiveEvent:(NSString *)name
                         payload:(NSDictionary<NSString *, id> *)payload;
```

`NativeWidgetPluginInstance.start(host:settings:)` calls optional `configureWithHost:settings:` before `start`.
It does nothing when called a second time while started. `settingsDidChange(_:)` forwards updated settings when the plugin implements that selector.
`sendEvent(name:payload:)` forwards an event when the plugin implements the optional event selector.
The current bridge accepts string-keyed dictionaries. The demo uses an integer setting named `tapCount` and a string event name.

When the plugin calls `saveSettings`, the host should validate and persist the values before sending `settingsDidChange` with the effective settings.
When it calls `requestPopup`, the host should create the popup view on demand and place it in the host's popup container.
These host callback policies are guidance for integration. The current StableBar UI does not yet provide this runtime bridge.

StableBar's `BarStore` already selects enabled native widgets that subscribe to an event and emits their widget IDs, event name, and string environment values through `NativeWidgetEvents`.
The loader's `sendEvent(name:payload:)` is not yet connected to that event source.
API v1 does not define a richer event payload or a stable list of event names.

The host calls `stop()` when it deactivates an instance. The loader makes `stop()` idempotent and also calls it when a started instance is released.
The instance retains its `Bundle` while it exists. Stop does not unload executable code from the process.
Keep plugin work and callbacks on the main actor. Release views and other references when stopping.

## Signature, trust, and consent

A valid signature proves that the signed files have not changed. It does not prove that the publisher is safe.
The current verifier checks all architectures, uses strict validation, checks nested code, and rejects unsigned or ad-hoc code.
It records the signature identifier, Team ID, and cdhash.

The trust store binds a grant to the package ID, bundle ID, exact package version, and exact signature.
A version or signature change needs a new grant. A grant can be revoked by package ID.
The trust store currently stores its data beside the installed packages in `native-plugin-trust.json`.

The loader checks bundle metadata, API major, signature identity, and the exact grant before it calls `Bundle.loadAndReturnError()`.
It checks the principal class and the plugin's reported API version after loading.
This order prevents an untrusted bundle from executing through the loader. It does not sandbox trusted code.

The package inspector reports native code as a review item. Current code does not yet connect a user consent screen to `NativePluginTrustStore.grant` or to the runtime loader.
Do not interpret package review or a successful signature check as an automatic trust grant.
The app integration must show the package identity, version, Team ID, and signature change to the user, then store explicit consent before loading.

## Hardened Runtime and process limits

When `SIGNING_IDENTITY` is set, the release build script signs StableBar with Hardened Runtime using `--options runtime`.
Without that variable, the script uses an ad-hoc signature.
`Resources/StableBar.entitlements` does not contain `com.apple.security.cs.disable-library-validation`.
Apple documents library validation as allowing code signed by the same Team ID or by Apple. A plugin signed by another team may therefore fail to load in a Hardened Runtime build.
Sign plugins with the host's Team ID unless the product deliberately adopts a broader signing policy.
Do not add the library-validation exception without reviewing the security and notarization impact. Apple notes that disabling this protection triggers extra Gatekeeper checks. See Apple's [Hardened Runtime guide](https://developer.apple.com/documentation/security/hardened-runtime), [library validation overview](https://developer.apple.com/videos/play/wwdc2023/10266/), and [Disable Library Validation entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation).

Native plugins run in the StableBar process. A plugin crash or main-thread hang can affect the whole app.
The API does not provide crash isolation, execution timeouts, or a safe code-unload operation.
The `stop()` callback is a lifecycle notification. It cannot undo arbitrary work or unload Swift and Objective-C runtime classes.
Use an out-of-process XPC design if the product needs fault isolation. That design is outside API v1.

## Current limits

- StableBar configuration accepts `type: "nativePlugin"`, and package inspection recognizes `nativeBundle`.
- The loader and trust-store checks are implemented and have targeted tests.
- The standalone demo harness has loaded the ad-hoc signed demo and exercised its protocol callbacks.
- StableBar does not yet connect `BarView` to `NativeWidgetPluginLoader`, render the native view, present its popup, forward settings, or route `NativeWidgetEvents` to plugin instances.
- End-to-end installation, consent, signing under the production identity, Hardened Runtime loading, and crash behavior have not been verified.
