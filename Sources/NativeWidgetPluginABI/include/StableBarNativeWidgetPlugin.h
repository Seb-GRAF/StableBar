#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

__attribute__((swift_attr("@MainActor")))
@protocol StableBarNativeWidgetHost <NSObject>
- (void)requestPopup;
- (void)saveSettings:(NSDictionary<NSString *, id> *)settings;
@end

__attribute__((swift_attr("@MainActor")))
@protocol StableBarNativeWidgetPlugin <NSObject>
@property(nonatomic, readonly) NSInteger apiVersion;
- (NSView *)makeWidgetView;
- (NSView *)makePopupView;
- (void)start;
- (void)stop;
@optional
- (void)configureWithHost:(id<StableBarNativeWidgetHost>)host
                 settings:(NSDictionary<NSString *, id> *)settings;
- (void)settingsDidChange:(NSDictionary<NSString *, id> *)settings;
- (void)stableBarDidReceiveEvent:(NSString *)name
                         payload:(NSDictionary<NSString *, id> *)payload;
@end

NS_ASSUME_NONNULL_END
