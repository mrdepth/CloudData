//
//  NSData+CloudData.h
//  CloudData
//
//  Created by Artem Shimanski on 13.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, BinaryDataCompressionLevel) {
	BinaryDataCompressionLevelNone,
	BinaryDataCompressionLevelDefault,
	BinaryDataCompressionLevelBest,
	BinaryDataCompressionLevelSpeed
};

@interface NSData (CloudData)
@property (nonatomic, nonnull, readonly) NSData* md5;

- (nullable NSData*) deflateWithCompressionLevel: (BinaryDataCompressionLevel) level NS_SWIFT_NAME(deflate(compressionLevel:));
- (nullable NSData*) inflate;

@end
