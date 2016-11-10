//
//  CDReachability.m
//  CloudData
//
//  Created by Artem Shimanski on 10.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import <arpa/inet.h>
#import <ifaddrs.h>
#import <netdb.h>
#import <sys/socket.h>
#import <netinet/in.h>

#import <CoreFoundation/CoreFoundation.h>

#import "CDReachability.h"

NSString *kCDReachabilityChangedNotification = @"kNetworkReachabilityChangedNotification";


#pragma mark - Supporting functions

#define kShouldPrintReachabilityFlags 0

static void PrintReachabilityFlags(SCNetworkReachabilityFlags flags, const char* comment)
{
#if kShouldPrintReachabilityFlags
	
	NSLog(@"Reachability Flag Status: %c%c %c%c%c%c%c%c%c %s\n",
		  (flags & kSCNetworkReachabilityFlagsIsWWAN)				? 'W' : '-',
		  (flags & kSCNetworkReachabilityFlagsReachable)            ? 'R' : '-',
		  
		  (flags & kSCNetworkReachabilityFlagsTransientConnection)  ? 't' : '-',
		  (flags & kSCNetworkReachabilityFlagsConnectionRequired)   ? 'c' : '-',
		  (flags & kSCNetworkReachabilityFlagsConnectionOnTraffic)  ? 'C' : '-',
		  (flags & kSCNetworkReachabilityFlagsInterventionRequired) ? 'i' : '-',
		  (flags & kSCNetworkReachabilityFlagsConnectionOnDemand)   ? 'D' : '-',
		  (flags & kSCNetworkReachabilityFlagsIsLocalAddress)       ? 'l' : '-',
		  (flags & kSCNetworkReachabilityFlagsIsDirect)             ? 'd' : '-',
		  comment
		  );
#endif
}


static void ReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void* info)
{
#pragma unused (target, flags)
	NSCAssert(info != NULL, @"info was NULL in ReachabilityCallback");
	NSCAssert([(__bridge NSObject*) info isKindOfClass: [CDReachability class]], @"info was wrong class in ReachabilityCallback");
	
	CDReachability* noteObject = (__bridge CDReachability *)info;
	[[NSNotificationCenter defaultCenter] postNotificationName: kCDReachabilityChangedNotification object: noteObject];
}

@interface CDReachability() {
	SCNetworkReachabilityRef _reachabilityRef;
}

@end


@implementation CDReachability

+ (instancetype)reachabilityWithHostName:(NSString *)hostName
{
	CDReachability* returnValue = NULL;
	SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(NULL, [hostName UTF8String]);
	if (reachability != NULL)
	{
		returnValue= [[self alloc] init];
		if (returnValue != NULL)
		{
			returnValue->_reachabilityRef = reachability;
		}
		else {
			CFRelease(reachability);
		}
	}
	return returnValue;
}


+ (instancetype)reachabilityWithAddress:(const struct sockaddr *)hostAddress
{
	SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, hostAddress);
	
	CDReachability* returnValue = NULL;
	
	if (reachability != NULL)
	{
		returnValue = [[self alloc] init];
		if (returnValue != NULL)
		{
			returnValue->_reachabilityRef = reachability;
		}
		else {
			CFRelease(reachability);
		}
	}
	return returnValue;
}


+ (instancetype)reachabilityForInternetConnection
{
	struct sockaddr_in zeroAddress;
	bzero(&zeroAddress, sizeof(zeroAddress));
	zeroAddress.sin_len = sizeof(zeroAddress);
	zeroAddress.sin_family = AF_INET;
	
	return [self reachabilityWithAddress: (const struct sockaddr *) &zeroAddress];
}

#pragma mark - Start and stop notifier

- (BOOL)startNotifier
{
	BOOL returnValue = NO;
	SCNetworkReachabilityContext context = {0, (__bridge void *)(self), NULL, NULL, NULL};
	
	if (SCNetworkReachabilitySetCallback(_reachabilityRef, ReachabilityCallback, &context))
	{
		if (SCNetworkReachabilityScheduleWithRunLoop(_reachabilityRef, CFRunLoopGetMain(), kCFRunLoopDefaultMode))
		{
			returnValue = YES;
		}
	}
	
	return returnValue;
}


- (void)stopNotifier
{
	if (_reachabilityRef != NULL)
	{
		SCNetworkReachabilityUnscheduleFromRunLoop(_reachabilityRef, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
	}
}


- (void)dealloc
{
	[self stopNotifier];
	if (_reachabilityRef != NULL)
	{
		CFRelease(_reachabilityRef);
	}
}


#pragma mark - Network Flag Handling

- (CDNetworkStatus)networkStatusForFlags:(SCNetworkReachabilityFlags)flags
{
	PrintReachabilityFlags(flags, "networkStatusForFlags");
	if ((flags & kSCNetworkReachabilityFlagsReachable) == 0)
	{
		// The target host is not reachable.
		return CDNetworkStatusNotReachable;
	}
	
	CDNetworkStatus returnValue = CDNetworkStatusNotReachable;
	
	if ((flags & kSCNetworkReachabilityFlagsConnectionRequired) == 0)
	{
		/*
		 If the target host is reachable and no connection is required then we'll assume (for now) that you're on Wi-Fi...
		 */
		returnValue = CDNetworkStatusReachableViaWiFi;
	}
	
	if ((((flags & kSCNetworkReachabilityFlagsConnectionOnDemand ) != 0) ||
		 (flags & kSCNetworkReachabilityFlagsConnectionOnTraffic) != 0))
	{
		/*
		 ... and the connection is on-demand (or on-traffic) if the calling application is using the CFSocketStream or higher APIs...
		 */
		
		if ((flags & kSCNetworkReachabilityFlagsInterventionRequired) == 0)
		{
			/*
			 ... and no [user] intervention is needed...
			 */
			returnValue = CDNetworkStatusReachableViaWiFi;
		}
	}
	
	if ((flags & kSCNetworkReachabilityFlagsIsWWAN) == kSCNetworkReachabilityFlagsIsWWAN)
	{
		/*
		 ... but WWAN connections are OK if the calling application is using the CFNetwork APIs.
		 */
		returnValue = CDNetworkStatusReachableViaWWAN;
	}
	
	return returnValue;
}


- (BOOL)connectionRequired
{
	NSAssert(_reachabilityRef != NULL, @"connectionRequired called with NULL reachabilityRef");
	SCNetworkReachabilityFlags flags;
	
	if (SCNetworkReachabilityGetFlags(_reachabilityRef, &flags))
	{
		return (flags & kSCNetworkReachabilityFlagsConnectionRequired);
	}
	
	return NO;
}


- (CDNetworkStatus)currentReachabilityStatus
{
	NSAssert(_reachabilityRef != NULL, @"currentNetworkStatus called with NULL SCNetworkReachabilityRef");
	CDNetworkStatus returnValue = CDNetworkStatusNotReachable;
	SCNetworkReachabilityFlags flags;
	
	if (SCNetworkReachabilityGetFlags(_reachabilityRef, &flags))
	{
		returnValue = [self networkStatusForFlags:flags];
	}
	
	return returnValue;
}


@end
