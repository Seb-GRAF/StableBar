import CoreGraphics
import Darwin

/// The private macOS calls StableBar makes, looked up at runtime rather than bound at launch. Each is nil on a macOS
/// that no longer has it, so the feature that needs it turns off and the rest of StableBar keeps working. Adding a
/// call is a maintainer's decision (AGENTS.md).
enum PrivateAPI {
    /// `RTLD_DEFAULT`: every image already loaded, which includes SkyLight through AppKit.
    private static var loaded: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: -2) }

    static func symbol<Function>(_ name: String, in image: UnsafeMutableRawPointer? = loaded, as type: Function.Type) -> Function? {
        dlsym(image, name).map { unsafeBitCast($0, to: type) }
    }

    // Hiding and revealing the macOS menu bar.
    static let mainConnectionID = symbol("CGSMainConnectionID", as: (@convention(c) () -> Int32).self)
    static let setMenuBarInsetAndAlpha = symbol(
        "CGSSetMenuBarInsetAndAlpha", as: (@convention(c) (Int32, Double, Double, Float) -> CGError).self)
    static let setMenuBarVisibilityOverride = symbol(
        "SLSSetMenuBarVisibilityOverrideOnDisplay", as: (@convention(c) (Int32, CGDirectDisplayID, Bool) -> CGError).self)

    // Reading Spaces. The copy calls return an array the caller owns.
    static let getActiveSpace = symbol("CGSGetActiveSpace", as: (@convention(c) (Int32) -> UInt64).self)
    static let copyManagedDisplaySpaces = symbol(
        "CGSCopyManagedDisplaySpaces", as: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self)
    static let copySpacesForWindows = symbol(
        "CGSCopySpacesForWindows", as: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self)

    /// Locking the screen, like the Apple menu's Lock Screen: the login framework's call, which returns 0 once locked.
    /// The framework stays open for good: closing it would leave this function pointing at unloaded code.
    static let lockScreenImmediate: (@convention(c) () -> Int32)? = {
        guard let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY) else {
            return nil
        }
        return symbol("SACLockScreenImmediate", in: login, as: (@convention(c) () -> Int32).self)
    }()
}
