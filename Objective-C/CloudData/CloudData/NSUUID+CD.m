//
//  NSUUID+CD.m
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "NSUUID+CD.h"
#import <CommonCrypto/CommonCrypto.h>

@implementation NSUUID (CD)

+ (instancetype) UUIDWithUbiquityIdentityToken:(id<NSCoding>) token {
	NSData* data = [NSKeyedArchiver archivedDataWithRootObject:token];
	const void *bytes = [data bytes];
	unsigned char result[16];
	CC_MD5(bytes, (CC_LONG) [data length], result);
	return [[NSUUID alloc] initWithUUIDBytes:bytes];
}

@end
