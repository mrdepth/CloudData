//
//  CDReachability.h
//  CloudData
//
//  Created by Artem Shimanski on 10.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <netinet/in.h>


typedef NS_ENUM(NSInteger, CDNetworkStatus) {
	CDNetworkStatusNotReachable = 0,
	CDNetworkStatusReachableViaWiFi,
	CDNetworkStatusReachableViaWWAN
};

extern NSString *kCDReachabilityChangedNotification;

@interface CDReachability : NSObject

+ (instancetype)reachabilityWithHostName:(NSString *)hostName;
+ (instancetype)reachabilityWithAddress:(const struct sockaddr *)hostAddress;
+ (instancetype)reachabilityForInternetConnection;

- (BOOL)startNotifier;
- (void)stopNotifier;

- (CDNetworkStatus)currentReachabilityStatus;
- (BOOL)connectionRequired;

@end


