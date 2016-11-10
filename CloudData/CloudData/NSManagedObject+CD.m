//
//  NSManagedObject+CD.m
//  CloudData
//
//  Created by Artem Shimanski on 10.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "NSManagedObject+CD.h"
#import "NSAttributeDescription+CD.h"
#import "NSRelationshipDescription+CD.h"
@import CloudKit;

@implementation NSManagedObject (CD)

- (NSDictionary<NSString*, id>*) changedValuesWithRecord:(CKRecord*) record {
	NSMutableDictionary* diff = [NSMutableDictionary new];
	for (NSPropertyDescription* property in self.entity.properties) {
		if ([property isKindOfClass:[NSAttributeDescription class]]) {
			NSAttributeDescription* attribute = (NSAttributeDescription*) property;
			id value1 = [attribute CKRecordValueFromBackingObject:self] ?: [NSNull null];
			id value2 = record[attribute.name] ?: [NSNull null];
			if (![value1 isEqualToString:value2])
				diff[attribute.name] = value1;
		}
		else if ([property isKindOfClass:[NSRelationshipDescription class]]) {
			NSRelationshipDescription* relationship = (NSRelationshipDescription*) property;
			id value1 = [relationship CKReferenceFromBackingObject:self recordZoneID:record.recordID.zoneID] ?: [NSNull null];
			id value2 = record[relationship.name] ?: [NSNull null];
			id a = [value1 isKindOfClass:[NSArray class]] ? [NSSet setWithArray:value1] : value1;
			id b = [value2 isKindOfClass:[NSArray class]] ? [NSSet setWithArray:value2] : value2;
			if (![value1 isEqualToString:value2])
				diff[relationship.name] = value1;
		}
	}
	return diff;
}

@end
