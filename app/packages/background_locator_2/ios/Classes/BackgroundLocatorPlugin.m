#import "BackgroundLocatorPlugin.h"
#import "Globals.h"
#import "Utils/Util.h"
#import "Preferences/PreferencesManager.h"
#import "InitPluggable.h"
#import "DisposePluggable.h"

// Adaptive tracking (see docs/developers/ios-location.md). The decisions
// (which request for which movement state) are made in Dart
// (app/lib/services/ios_location_profile.dart); this file applies them. The
// only native decision is the wake-up: on exit of the still-mode region the
// plugin switches back to the registration ("slow") request on its own,
// because the Dart isolate may not be running at that moment.

/// Identifier of the exit region armed in still mode.
static NSString *const kStillRegionId = @"orbitly.still";
/// Identifier of the exit region armed at termination (legacy name).
static NSString *const kTerminateRegionId = @"region";
/// A fix at least this accurate can be the center of a region. Mirrors
/// IosLocationConfig.coarseAccuracyM in Dart.
static const CLLocationAccuracy kGoodAccuracyM = 100.0;
/// Smallest radius of the termination region (Apple: small regions fire late
/// or not at all).
static const CLLocationDistance kTerminateRegionMinRadiusM = 150.0;
/// Oldest fix that may still be the center of the still region.
static const NSTimeInterval kStillCenterMaxAgeSeconds = 1800.0;
/// Liveness tick for the Dart heartbeat callback (Android uses an alarm).
static const NSTimeInterval kHeartbeatSeconds = 300.0;

static CLLocationDistance FilterForMeters(double meters) {
    return meters > 0 ? meters : kCLDistanceFilterNone;
}

static double NumberArgument(NSDictionary *arguments, NSString *key, double fallback) {
    id value = [arguments objectForKey:key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value doubleValue];
    }
    return fallback;
}

@implementation BackgroundLocatorPlugin {
    FlutterEngine *_headlessRunner;
    FlutterMethodChannel *_callbackChannel;
    FlutterMethodChannel *_mainChannel;
    NSObject<FlutterPluginRegistrar> *_registrar;
    CLLocationManager *_locationManager;
    CLLocation* _lastLocation;
    /// Newest fix with a horizontal accuracy <= kGoodAccuracyM.
    CLLocation *_lastGoodLocation;
    /// A fix the Dart isolate could not take yet (engine still starting).
    CLLocation *_pendingLocation;
    /// Dart asked for the still request (3 km accuracy plus wake region).
    BOOL _stillMode;
    double _stillRegionRadius;
    BOOL _stillRegionArmed;
    BOOL _stillRegionFailed;
    /// The request was changed natively; flag the next delivered fix.
    BOOL _nativeReset;
    NSTimer *_heartbeatTimer;
}

static FlutterPluginRegistrantCallback registerPlugins = nil;
static BackgroundLocatorPlugin *instance = nil;

#pragma mark FlutterPlugin Methods

+ (void)registerWithRegistrar:(nonnull NSObject<FlutterPluginRegistrar> *)registrar {
    @synchronized(self) {
        if (instance == nil) {
            instance = [[BackgroundLocatorPlugin alloc] init:registrar];
            [registrar addApplicationDelegate:instance];
        } else {
            // A second engine (the headless background engine) registers its
            // plugins too. Give its isolate the main channel as well, so the
            // background isolate can call updateLocationRequest (the adaptive
            // cadence runs there). Same singleton, same location manager.
            FlutterMethodChannel *channel =
                [FlutterMethodChannel methodChannelWithName:kChannelId
                                            binaryMessenger:[registrar messenger]];
            [registrar addMethodCallDelegate:instance channel:channel];
        }
    }
}

+ (void)setPluginRegistrantCallback:(FlutterPluginRegistrantCallback)callback {
    registerPlugins = callback;
}

+ (BackgroundLocatorPlugin *) getInstance {
    return instance;
}

- (void)invokeMethod:(NSString*_Nonnull)method arguments:(id _Nullable)arguments {
    // Return if flutter engine is not ready
    NSString *isolateId = [_headlessRunner isolateId];
    if (_callbackChannel == nil || isolateId == nil) {
        return;
    }

    [_callbackChannel invokeMethod:method arguments:arguments];
}

- (void)handleMethodCall:(FlutterMethodCall *)call
                  result:(FlutterResult)result {
    MethodCallHelper *callHelper = [[MethodCallHelper alloc] init];
    [callHelper handleMethodCall:call result:result delegate:self];
}

//https://medium.com/@calvinlin_96474/ios-11-continuous-background-location-update-by-swift-4-12ce3ac603e3
// iOS will launch the app when new location received
- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Check to see if we're being launched due to a location event.
    if (launchOptions[UIApplicationLaunchOptionsLocationKey] != nil) {
        // Relaunched after termination by a significant-change or region
        // event: restart the headless isolate and the whole pipeline (the
        // older "one fix per region hop" mode is gone).
        [self startLocatorService:[PreferencesManager getCallbackDispatcherHandle]];
        [PreferencesManager setObservingRegion:NO];
        if ([PreferencesManager isServiceRunning]) {
            [self resumeAfterRelaunch];
        }
    } else if([PreferencesManager isObservingRegion]) {
        [self prepareLocationManager];
        [self removeLocator];
        [PreferencesManager setObservingRegion:NO];
        [_locationManager startUpdatingLocation];
    }

    // Note: if we return NO, this vetos the launch of the application.
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    if ([PreferencesManager isServiceRunning]) {
        [_locationManager startMonitoringSignificantLocationChanges];
    }
}

-(void)applicationWillTerminate:(UIApplication *)application {
    if ([PreferencesManager isServiceRunning]) {
        CLLocation *center = _lastGoodLocation != nil ? _lastGoodLocation : _lastLocation;
        if (center != nil) {
            [self observeRegionForLocation:center];
        }
    }
    if([PreferencesManager isStopWithTerminate]){
        [self removeLocator];
    }
}

- (void) observeRegionForLocation:(CLLocation *)location {
    if (![CLLocationManager isMonitoringAvailableForClass:[CLCircularRegion class]]) {
        return;
    }
    double radius = MAX([PreferencesManager getDistanceFilter], kTerminateRegionMinRadiusM);
    CLRegion* region = [[CLCircularRegion alloc] initWithCenter:location.coordinate
                                                         radius:radius
                                                     identifier:kTerminateRegionId];
    region.notifyOnEntry = false;
    region.notifyOnExit = true;
    [_locationManager startMonitoringForRegion:region];
}

- (void) prepareLocationMap:(CLLocation*) location {
    _lastLocation = location;
    NSMutableDictionary *locationMap = [[Util getLocationMap:location] mutableCopy];
    if (_nativeReset) {
        [locationMap setObject:@YES forKey:kArgNativeReset];
    }
    if ([self sendLocationEvent:locationMap]) {
        _nativeReset = NO;
        _pendingLocation = nil;
    } else {
        // The isolate is still starting (relaunch): deliver this fix once it
        // reports LocatorService.initialized.
        _pendingLocation = location;
    }
}

#pragma mark LocationManagerDelegate Methods
- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray<CLLocation *> *)locations {
    // Ordered oldest to newest: the last one is the current position.
    CLLocation *location = [locations lastObject];
    if (location == nil) {
        return;
    }
    if (location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= kGoodAccuracyM) {
        _lastGoodLocation = location;
        if (_stillMode && !_stillRegionArmed && !_stillRegionFailed) {
            [self armStillRegionAt:location];
        }
    }
    [self prepareLocationMap:location];
}

- (void)locationManager:(CLLocationManager *)manager didExitRegion:(CLRegion *)region {
    [_locationManager stopMonitoringForRegion:region];
    if (![PreferencesManager isServiceRunning]) {
        return;
    }
    // Still-mode region or termination region: the phone left the spot.
    [self wakeUp];
}

- (void)locationManager:(CLLocationManager *)manager
monitoringDidFailForRegion:(CLRegion *)region
              withError:(NSError *)error {
    NSLog(@"background_locator_2: region monitoring failed: %@", error);
    if (region != nil && [region.identifier isEqualToString:kStillRegionId] && _stillMode) {
        // No wake region: Wi-Fi accuracy lets the distance filter notice
        // leaving instead (costs more than cell-only, far less than GPS).
        _stillRegionArmed = NO;
        _stillRegionFailed = YES;
        _locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters;
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    // kCLErrorLocationUnknown is transient; Core Location keeps trying.
    if (error.code != kCLErrorLocationUnknown) {
        NSLog(@"background_locator_2: location error: %@", error);
    }
}

#pragma mark Adaptive request

/// The registration request (Dart: iosSlowRequest): used at registration,
/// after a relaunch and on every native wake-up.
- (void)applySlowRequest {
    _locationManager.desiredAccuracy = [Util getAccuracy:[PreferencesManager getAccuracy]];
    _locationManager.distanceFilter = FilterForMeters([PreferencesManager getDistanceFilter]);
    _locationManager.activityType = CLActivityTypeOther;
}

- (void)stopMonitoringRegionsWithIdentifier:(NSString *)identifier {
    for (CLRegion *region in [[_locationManager monitoredRegions] allObjects]) {
        if ([region.identifier isEqualToString:identifier]) {
            [_locationManager stopMonitoringForRegion:region];
        }
    }
}

- (void)armStillRegionAt:(CLLocation *)center {
    CLLocationDistance radius = MAX(_stillRegionRadius, center.horizontalAccuracy);
    CLLocationDistance maxRadius = _locationManager.maximumRegionMonitoringDistance;
    if (maxRadius > 0 && radius > maxRadius) {
        radius = maxRadius;
    }
    CLCircularRegion *region = [[CLCircularRegion alloc] initWithCenter:center.coordinate
                                                                 radius:radius
                                                             identifier:kStillRegionId];
    region.notifyOnEntry = NO;
    region.notifyOnExit = YES;
    // Same identifier: replaces a region armed earlier.
    [_locationManager startMonitoringForRegion:region];
    _stillRegionArmed = YES;
    NSLog(@"background_locator_2: still region armed, radius=%.0f", radius);
}

- (void)enterStillModeWithRadius:(double)radius {
    _stillMode = YES;
    _stillRegionRadius = radius;
    _stillRegionArmed = NO;
    _stillRegionFailed = NO;
    if (![CLLocationManager isMonitoringAvailableForClass:[CLCircularRegion class]]) {
        _stillRegionFailed = YES;
        _locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters;
        return;
    }
    // Only a recent good fix is a trustworthy center (still mode starts 10
    // to 15 minutes after the last movement fix).
    CLLocation *center = _lastGoodLocation;
    if (center != nil && -[center.timestamp timeIntervalSinceNow] <= kStillCenterMaxAgeSeconds) {
        [self armStillRegionAt:center];
    }
    // Otherwise armed at the next good fix (didUpdateLocations).
}

- (void)leaveStillMode {
    _stillMode = NO;
    _stillRegionArmed = NO;
    _stillRegionFailed = NO;
    [self stopMonitoringRegionsWithIdentifier:kStillRegionId];
}

/// The phone probably moved while the cheap request was active: back to the
/// slow request now, and restart updates so a fresh fix arrives at once.
- (void)wakeUp {
    NSLog(@"background_locator_2: wake-up (region exit), slow request");
    [self leaveStillMode];
    [self applySlowRequest];
    _nativeReset = YES;
    [_locationManager stopUpdatingLocation];
    [_locationManager startUpdatingLocation];
}

- (void)resumeAfterRelaunch {
    NSLog(@"background_locator_2: relaunched by a location event, resuming");
    if (@available(iOS 11.0, *)) {
        _locationManager.showsBackgroundLocationIndicator =
            [PreferencesManager showsBackgroundLocationIndicator];
    }
    if (@available(iOS 9.0, *)) {
        _locationManager.allowsBackgroundLocationUpdates = YES;
    }
    // Keep any armed region: its pending exit event is delivered after
    // launch and calls wakeUp.
    _stillMode = NO;
    _stillRegionArmed = NO;
    _stillRegionFailed = NO;
    [self applySlowRequest];
    _nativeReset = YES;
    [self startHeartbeat];
    [_locationManager startUpdatingLocation];
    [_locationManager startMonitoringSignificantLocationChanges];
}

- (void)startHeartbeat {
    [_heartbeatTimer invalidate];
    // Main run loop (all callers run on the main thread). The timer retains
    // self; the plugin is a process-wide singleton and removeLocator
    // invalidates the timer.
    _heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:kHeartbeatSeconds
                                                       target:self
                                                     selector:@selector(heartbeatFired:)
                                                     userInfo:nil
                                                      repeats:YES];
    _heartbeatTimer.tolerance = 30.0;
}

- (void)stopHeartbeat {
    [_heartbeatTimer invalidate];
    _heartbeatTimer = nil;
}

- (void)heartbeatFired:(NSTimer *)timer {
    int64_t handle = [PreferencesManager getCallbackHandle:kHeartbeatCallbackKey];
    if (handle == 0) {
        return;
    }
    [self invokeMethod:kBCMSendHeartbeat arguments:@{kArgHeartbeatCallback: @(handle)}];
}

#pragma mark LocatorPlugin Methods
- (BOOL) sendLocationEvent: (NSDictionary *)location {
    NSString *isolateId = [_headlessRunner isolateId];
    if (_callbackChannel == nil || isolateId == nil) {
        return NO;
    }

    NSDictionary *map = @{
                     kArgCallback : @([PreferencesManager getCallbackHandle:kCallbackKey]),
                     kArgLocation: location
                     };
    [_callbackChannel invokeMethod:kBCMSendLocation arguments:map];
    return YES;
}

- (instancetype)init:(NSObject<FlutterPluginRegistrar> *)registrar {
    self = [super init];

    _headlessRunner = [[FlutterEngine alloc] initWithName:@"LocatorIsolate" project:nil allowHeadlessExecution:YES];
    _registrar = registrar;
    [self prepareLocationManager];

    _mainChannel = [FlutterMethodChannel methodChannelWithName:kChannelId
                                               binaryMessenger:[registrar messenger]];
    [registrar addMethodCallDelegate:self channel:_mainChannel];

    _callbackChannel =
    [FlutterMethodChannel methodChannelWithName:kBackgroundChannelId
                                binaryMessenger:[_headlessRunner binaryMessenger] ];
    return self;
}

- (void) prepareLocationManager {
    _locationManager = [[CLLocationManager alloc] init];
    [_locationManager setDelegate:self];
    // Never let iOS pause on its own: a paused background app gets no updates
    // until it is opened again. Still mode (3 km accuracy plus exit region)
    // is the controlled replacement. See docs/developers/ios-location.md.
    _locationManager.pausesLocationUpdatesAutomatically = NO;
}

#pragma mark MethodCallHelperDelegate

- (void)startLocatorService:(int64_t)handle {
    [PreferencesManager setCallbackDispatcherHandle:handle];
    FlutterCallbackInformation *info = [FlutterCallbackCache lookupCallbackInformation:handle];
    NSAssert(info != nil, @"failed to find callback");

    NSString *entrypoint = info.callbackName;
    NSString *uri = info.callbackLibraryPath;
    [_headlessRunner runWithEntrypoint:entrypoint libraryURI:uri];
    NSAssert(registerPlugins != nil, @"failed to set registerPlugins");

    // Once our headless runner has been started, we need to register the application's plugins
    // with the runner in order for them to work on the background isolate. `registerPlugins` is
    // a callback set from AppDelegate.m in the main application. This callback should register
    // all relevant plugins (excluding those which require UI).
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        registerPlugins(_headlessRunner);
    });
    [_registrar addMethodCallDelegate:self channel:_callbackChannel];
}

- (void)registerLocator:(int64_t)callback
           initCallback:(int64_t)initCallback
  initialDataDictionary:(NSDictionary*)initialDataDictionary
        disposeCallback:(int64_t)disposeCallback
               settings: (NSDictionary*)settings {
    [self->_locationManager requestAlwaysAuthorization];

    long accuracyKey = [[settings objectForKey:kSettingsAccuracy] longValue];
    double distanceFilter= [[settings objectForKey:kSettingsDistanceFilter] doubleValue];
    bool  showsBackgroundLocationIndicator=[[settings objectForKey:kSettingsShowsBackgroundLocationIndicator] boolValue];
    bool  stopWithTerminate=[[settings objectForKey:kSettingsStopWithTerminate] boolValue];
    int64_t heartbeatCallback = [[settings objectForKey:kArgHeartbeatCallback] longLongValue];

    [PreferencesManager saveAccuracy:accuracyKey];
    [PreferencesManager saveDistanceFilter:distanceFilter];
    [PreferencesManager setShowsBackgroundLocationIndicator:showsBackgroundLocationIndicator];
    [PreferencesManager setStopWithTerminate:stopWithTerminate];
    [PreferencesManager setCallbackHandle:heartbeatCallback key:kHeartbeatCallbackKey];

    [self leaveStillMode];
    [self applySlowRequest];
    // The Dart cadence may have applied another request before this
    // (re-)registration: tell it with the next fix.
    _nativeReset = YES;

    if (@available(iOS 11.0, *)) {
      _locationManager.showsBackgroundLocationIndicator = showsBackgroundLocationIndicator;
    }

    if (@available(iOS 9.0, *)) {
        _locationManager.allowsBackgroundLocationUpdates = YES;
    }

    [PreferencesManager setCallbackHandle:callback key:kCallbackKey];

    InitPluggable *initPluggable = [[InitPluggable alloc] init];
    [initPluggable setCallback:initCallback];
    [initPluggable onServiceStart:initialDataDictionary];

    DisposePluggable *disposePluggable = [[DisposePluggable alloc] init];
    [disposePluggable setCallback:disposeCallback];

    [self startHeartbeat];
    [_locationManager startUpdatingLocation];
    [_locationManager startMonitoringSignificantLocationChanges];
}

- (BOOL)updateLocationRequest:(NSDictionary *)arguments {
    id accuracyArgument = [arguments objectForKey:kArgRequestIosAccuracy];
    if (_locationManager == nil || ![PreferencesManager isServiceRunning] ||
        ![accuracyArgument isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    double stillRadius = NumberArgument(arguments, kArgRequestIosStillRegionM, 0);
    _locationManager.desiredAccuracy = [Util requestAccuracy:[accuracyArgument longValue]];
    _locationManager.distanceFilter =
        FilterForMeters(NumberArgument(arguments, kArgRequestIosDistanceFilter, 0));
    _locationManager.activityType =
        [Util activityType:(long)NumberArgument(arguments, kArgRequestIosActivityType, 0)];
    if (stillRadius > 0) {
        [self enterStillModeWithRadius:stillRadius];
    } else {
        [self leaveStillMode];
    }
    // No coordinates in logs: request parameters only.
    NSLog(@"background_locator_2: request accuracy=%.0f filter=%.0f activity=%ld still=%.0f",
          _locationManager.desiredAccuracy, _locationManager.distanceFilter,
          (long)_locationManager.activityType, stillRadius);
    return YES;
}

- (void)serviceInitialized {
    CLLocation *pending = _pendingLocation;
    if (pending != nil) {
        [self prepareLocationMap:pending];
    }
}

- (void)removeLocator {
    if (_locationManager == nil) {
        return;
    }

    @synchronized (self) {
        [self stopHeartbeat];
        _stillMode = NO;
        _stillRegionArmed = NO;
        _stillRegionFailed = NO;
        _nativeReset = NO;
        _pendingLocation = nil;

        [_locationManager stopUpdatingLocation];

        if (@available(iOS 9.0, *)) {
            _locationManager.allowsBackgroundLocationUpdates = NO;
        }

        [_locationManager stopMonitoringSignificantLocationChanges];

        for (CLRegion* region in [[_locationManager monitoredRegions] allObjects]) {
            [_locationManager stopMonitoringForRegion:region];
        }
    }

    DisposePluggable *disposePluggable = [[DisposePluggable alloc] init];
    [disposePluggable onServiceDispose];
}

- (void) setServiceRunning:(BOOL) value {
    @synchronized(self) {
        [PreferencesManager setServiceRunning:value];
    }
}

- (BOOL)isServiceRunning{
    return [PreferencesManager isServiceRunning];
}

- (BOOL)isStopWithTerminate{
    return [PreferencesManager isStopWithTerminate];
}

@end
