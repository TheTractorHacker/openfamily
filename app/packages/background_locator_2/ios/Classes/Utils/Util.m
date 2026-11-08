//
//  Util.m
//  background_locator_2
//
//  Created by Mehdi Sohrabi on 6/28/20.
//

#import "Util.h"
#import "GLobals.h"

@implementation Util

+ (CLLocationAccuracy) getAccuracy:(long)key {
    switch (key) {
        case 0:
            return kCLLocationAccuracyKilometer;
        case 1:
            return kCLLocationAccuracyHundredMeters;
        case 2:
            return kCLLocationAccuracyNearestTenMeters;
        case 3:
            return kCLLocationAccuracyBest;
        case 4:
            return kCLLocationAccuracyBestForNavigation;
        default:
            return kCLLocationAccuracyBestForNavigation;
    }
}

// Mirrors IOSAccuracy in lib/settings/ios_settings.dart.
+ (CLLocationAccuracy) requestAccuracy:(long)code {
    switch (code) {
        case 0:
            return kCLLocationAccuracyThreeKilometers;
        case 1:
            return kCLLocationAccuracyKilometer;
        case 2:
            return kCLLocationAccuracyHundredMeters;
        case 3:
            return kCLLocationAccuracyNearestTenMeters;
        case 4:
            return kCLLocationAccuracyBest;
        case 5:
            return kCLLocationAccuracyBestForNavigation;
        default:
            return kCLLocationAccuracyNearestTenMeters;
    }
}

// Mirrors IOSActivityType in lib/settings/ios_settings.dart.
+ (CLActivityType) activityType:(long)code {
    switch (code) {
        case 1:
            return CLActivityTypeAutomotiveNavigation;
        case 2:
            return CLActivityTypeFitness;
        case 3:
            return CLActivityTypeOtherNavigation;
        default:
            return CLActivityTypeOther;
    }
}

+ (NSDictionary<NSString *,NSNumber *> *)getLocationMap:(CLLocation *)location {
    NSTimeInterval timeInSeconds = [location.timestamp timeIntervalSince1970];
    return @{
            kArgLatitude: @(location.coordinate.latitude),
            kArgLongitude: @(location.coordinate.longitude),
            kArgAccuracy: @(location.horizontalAccuracy),
            kArgAltitude: @(location.altitude),
            kArgSpeed: @(location.speed),
            kArgSpeedAccuracy: @(0.0),
            kArgHeading: @(location.course),
            kArgTime: @(((double) timeInSeconds) * 1000.0)  // in milliseconds since the epoch
        };
}

@end
