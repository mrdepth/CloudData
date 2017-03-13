//
//  NSData+md5.m
//  CloudData
//
//  Created by Artem Shimanski on 13.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

#import "NSData+md5.h"
#import <CommonCrypto/CommonCrypto.h>

@implementation NSData (md5)

- (NSData*) md5 {
	const void *bytes = [self bytes];
	unsigned char result[CC_MD5_DIGEST_LENGTH];
	CC_MD5(bytes, (CC_LONG) [self length], result);
	return [NSData dataWithBytes:result length:CC_MD5_DIGEST_LENGTH];

}
@end
