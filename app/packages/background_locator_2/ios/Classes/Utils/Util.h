//
//  Util.h
//  background_locator_2
//
//  Created by Mehdi Sohrabi on 6/28/20.
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Util : NSObject

+ (CLLocationAccuracy) getAccuracy:(long)key;
/// Accuracy code of updateLocationRequest (IOSAccuracy.code in Dart).
+ (CLLocationAccuracy) requestAccuracy:(long)code;
/// Activity type code of updateLocationRequest (IOSActivityType.code in Dart).
+ (CLActivityType) activityType:(long)code;
+ (NSDictionary<NSString*,NSNumber*>*) getLocationMap:(CLLocation *)location;

@end

NS_ASSUME_NONNULL_END
