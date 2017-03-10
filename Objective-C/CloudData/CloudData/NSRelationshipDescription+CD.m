//
//  NSRelationshipDescription+CD.m
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "NSRelationshipDescription+CD.h"
#import "CDCloudStore.h"
#import "CDCloudStore+Protected.h"

@implementation NSRelationshipDescription (CD)

- (BOOL) shouldSerialize {
	if (self.inverseRelationship) {
		if (self.inverseRelationship.deleteRule == NSCascadeDeleteRule)
			return YES;
		else if (self.deleteRule == NSCascadeDeleteRule)
			return NO;
		else {
			if (self.toMany) {
				if (self.inverseRelationship.toMany)
					return [self.entity.name compare:self.inverseRelationship.name] == NSOrderedAscending;
				else
					return NO;
			}
			else {
				if (self.inverseRelationship.toMany)
					return YES;
				else
					return [self.entity.name compare:self.inverseRelationship.name] == NSOrderedAscending;
			}
		}
	}
	else
		return YES;
}

- (id) CKReferenceFromBackingObject:(NSManagedObject*) object recordZoneID:(CKRecordZoneID*) recordZoneID {
	__block id result = nil;
	[object.managedObjectContext performBlockAndWait:^{
		CKReferenceAction action = self.inverseRelationship.deleteRule == NSCascadeDeleteRule ? CKReferenceActionDeleteSelf : CKReferenceActionNone;

		id value = [object valueForKey:self.name];
		CDCloudStore* store = (CDCloudStore*) object.objectID.persistentStore;
		if ([self isToMany]) {
			NSMutableArray* references = [NSMutableArray new];
			for (NSManagedObject* object in value) {
				CDRecord* record = [object valueForKey:@"CDRecord"];
				CKReference* reference = [[CKReference alloc] initWithRecordID:[[CKRecordID alloc] initWithRecordName:record.recordID zoneID:recordZoneID] action:action];
				[references addObject:reference];
			}
			result = references;
			return;
		}
		else if (value) {
			CDRecord* record = [value valueForKey:@"CDRecord"];
			result = [[CKReference alloc] initWithRecordID:[[CKRecordID alloc] initWithRecordName:record.recordID zoneID:recordZoneID] action:action];
		}
	}];
	return result;
}

- (id) managedReferenceFromCKRecord:(CKRecord*) record inStore:(CDCloudStore*) store {
	NSParameterAssert(record != nil);
	NSParameterAssert(store != nil);
	id value = record[self.name];
	if (self.isToMany) {
		NSMutableSet* set = [NSMutableSet new];
		for (CKReference* reference in value) {
			if ([value isKindOfClass:[CKReference class]])
				[set addObject:[self managedReferenceFromCKReference:reference inStore:store]];
		}
		return set;
	}
	else {
		CKReference* reference = [value isKindOfClass:[NSArray class]] ? [value lastObject] : value;
		if ([value isKindOfClass:[CKReference class]])
			return [self managedReferenceFromCKReference:reference inStore:store];
		else
			return [NSNull null];
	}
}

- (NSManagedObjectID*) managedReferenceFromCKReference:(CKReference*) reference inStore:(CDCloudStore*) store {
	return [store.backingObjectsHelper objectIDWithRecordID:reference.recordID.recordName entityName:self.destinationEntity.name];
}

@end
