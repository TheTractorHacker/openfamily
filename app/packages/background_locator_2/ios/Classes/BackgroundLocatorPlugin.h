#import <Flutter/Flutter.h>
#import <CoreLocation/CoreLocation.h>
#import "MethodCallHelper.h"

@interface BackgroundLocatorPlugin : NSObject<FlutterPlugin, CLLocationManagerDelegate, MethodCallHelperDelegate>

/// Must be called from the host AppDelegate before the headless engine starts:
/// the callback registers the app's plugins with the background engine.
+ (void)setPluginRegistrantCallback:(FlutterPluginRegistrantCallback _Nonnull)callback;
+ (BackgroundLocatorPlugin*_Nullable) getInstance;
- (void)invokeMethod:(NSString*_Nonnull)method arguments:(id _Nullable)arguments;

@end
