//
//  CDRecordTransformer.m
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "CDRecordTransformer.h"
@import CloudKit;

@implementation CDRecordTransformer

+ (void) load {
	[NSValueTransformer setValueTransformer:[self new] forName:@"CDRecordTransformer"];
}

+ (Class)transformedValueClass {
	return [NSData class];
}

+ (BOOL)allowsReverseTransformation {
	return YES;
}

- (id)transformedValue:(id)value {
	NSMutableData* data = [NSMutableData new];
	NSKeyedArchiver* archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:data];
	[(CKRecord*) value encodeSystemFieldsWithCoder:archiver];
	[archiver finishEncoding];
	return data;
}

- (id) reverseTransformedValue:(id)value {
	NSKeyedUnarchiver* unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:value];
	return [[CKRecord alloc] initWithCoder:unarchiver];
}

@end
