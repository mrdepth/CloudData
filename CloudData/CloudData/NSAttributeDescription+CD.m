//
//  NSAttributeDescription+CD.m
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "NSAttributeDescription+CD.h"

@implementation NSAttributeDescription (CD)

- (id) reverseTransformValue:(id) value {
	if ([value isKindOfClass:[NSNull class]])
		value = nil;
	
	switch (self.attributeType) {
		case NSUndefinedAttributeType:
		case NSObjectIDAttributeType:
			NSAssert(NO, @"Invalid attribute type %ld", (long) self.attributeType);
			break;
		case NSInteger16AttributeType:
		case NSInteger32AttributeType:
		case NSInteger64AttributeType:
		case NSDecimalAttributeType:
		case NSDoubleAttributeType:
		case NSFloatAttributeType:
		case NSBooleanAttributeType:
			if (!value)
				value = self.defaultValue ?: @(0);
			break;
		case NSStringAttributeType:
		case NSDateAttributeType:
		case NSBinaryDataAttributeType:
			break;
		case NSTransformableAttributeType:
			if (value) {
				if (self.attributeType == NSTransformableAttributeType) {
					if (self.valueTransformerName)
						value = [[NSValueTransformer valueTransformerForName:self.valueTransformerName] reverseTransformedValue:value];
					else
						value = [NSKeyedUnarchiver unarchiveObjectWithData:value];
				}
			}
			break;
	};
	return value;
}

- (id) transformedValue:(id)value {
	if (value) {
		if (self.attributeType == NSTransformableAttributeType) {
			if (self.valueTransformerName)
				value = [[NSValueTransformer valueTransformerForName:self.valueTransformerName] transformedValue:value];
			else
				value = [NSKeyedArchiver archivedDataWithRootObject:value];
		}
	}
	return value;
}

@end
