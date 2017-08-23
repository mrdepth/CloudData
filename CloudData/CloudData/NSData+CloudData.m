//
//  NSData+CloudData.m
//  CloudData
//
//  Created by Artem Shimanski on 13.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

#import "NSData+CloudData.h"
#import <CommonCrypto/CommonCrypto.h>
#import <zlib.h>

const uInt chunkSize = 1024 * 4 * sizeof(Bytef);

@implementation NSData (md5)

- (NSData*) md5 {
	const void *bytes = [self bytes];
	unsigned char result[CC_MD5_DIGEST_LENGTH];
	CC_MD5(bytes, (CC_LONG) [self length], result);
	return [NSData dataWithBytes:result length:CC_MD5_DIGEST_LENGTH];

}

- (nullable NSData*) deflateWithCompressionLevel: (BinaryDataCompressionLevel) level {
	int l = Z_DEFAULT_COMPRESSION;
	
	switch (level) {
		case BinaryDataCompressionLevelNone:
			return self;
		case BinaryDataCompressionLevelDefault:
			l = Z_DEFAULT_COMPRESSION;
			break;
		case BinaryDataCompressionLevelBest:
			l = Z_BEST_COMPRESSION;
			break;
		case BinaryDataCompressionLevelSpeed:
			l = Z_BEST_SPEED;
			break;
	}

	z_stream strm;
	memset(&strm, 0, sizeof(strm));
	strm.zalloc = Z_NULL;
	strm.zfree = Z_NULL;
	strm.opaque = Z_NULL;
	
	
	if (deflateInit(&strm, (int) l) != Z_OK) {
		return nil;
	}
	
	NSMutableData* output = [NSMutableData new];
	Bytef* chunk = (Bytef*) malloc(chunkSize);
	
	strm.next_in = (z_const Bytef*) self.bytes;
	strm.avail_in = (uInt) self.length;
	
	do {
		strm.next_out = chunk;
		strm.avail_out = chunkSize;
		int res = deflate(&strm, Z_FINISH);
		if (res != Z_OK && res != Z_STREAM_END) {
			output = nil;
			break;
		}
		[output appendBytes:chunk length:chunkSize - strm.avail_out];
	}
	while (strm.avail_out == 0);
	free(chunk);
	deflateEnd(&strm);
	return output;
}

- (nullable NSData*) inflate {
	z_stream strm;
	memset(&strm, 0, sizeof(strm));
	strm.zalloc = Z_NULL;
	strm.zfree = Z_NULL;
	strm.opaque = Z_NULL;
	
	if (inflateInit(&strm) != Z_OK) {
		return nil;
	}
	
	NSMutableData* output = [NSMutableData new];
	Bytef* chunk = (Bytef*) malloc(chunkSize);
	
	strm.next_in = (z_const Bytef*) self.bytes;
	strm.avail_in = (uInt) self.length;
	
	do {
		strm.next_out = chunk;
		strm.avail_out = chunkSize;
		int res = inflate(&strm, Z_NO_FLUSH);
		if (res != Z_OK && res != Z_STREAM_END) {
			output = nil;
			break;
		}
		[output appendBytes:chunk length:chunkSize - strm.avail_out];
	}
	while (strm.avail_out == 0);
	free(chunk);
	inflateEnd(&strm);
	return output;

}

@end
