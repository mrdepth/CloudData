//
//  CDBackingObjectHelper.m
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "CDBackingObjectHelper.h"
#import "CDCloudStore.h"
#import "CDRecord+CoreDataClass.h"

@interface CDCloudStore()
@property (nonatomic, strong) NSDictionary<NSString*, NSEntityDescription*>* entities;
@end


@interface CDBackingObjectHelper()
@property (nonatomic, weak) CDCloudStore* store;
@property (nonatomic, strong) NSManagedObjectContext* managedObjectContext;
@end

@implementation CDBackingObjectHelper

- (id) initWithStore:(CDCloudStore*) store managedObjectContext:(NSManagedObjectContext*) managedObjectContext {
	if (self = [super init]) {
		self.store = store;
		self.managedObjectContext = managedObjectContext;
	}
	return self;
}

- (NSManagedObject*) backingObjectWithObjectID:(NSManagedObjectID*) objectID {
	NSFetchRequest* request = [NSFetchRequest fetchRequestWithEntityName:objectID.entity.name];
	request.predicate = [NSPredicate predicateWithFormat:@"CDRecord.recordID == %@", [self.store referenceObjectForObjectID:objectID]];
	request.fetchLimit = 1;
	return [[self.managedObjectContext executeFetchRequest:request error:nil] lastObject];
}

- (NSManagedObject*) backingObjectWithRecordID:(NSString*) recordID {
	CDRecord* record = [self recordWithRecordID:recordID];
	return [record valueForKey:record.recordType];
}

- (CDRecord*) recordWithObjectID:(NSManagedObjectID*) objectID {
	return [self recordWithRecordID:[self.store referenceObjectForObjectID:objectID]];
}

- (CDRecord*) recordWithRecordID:(NSString*) recordID {
	NSFetchRequest* request = [NSFetchRequest fetchRequestWithEntityName:@"CDRecord"];
	request.predicate = [NSPredicate predicateWithFormat:@"recordID == %@", recordID];
	request.fetchLimit = 1;
	return [[self.managedObjectContext executeFetchRequest:request error:nil] lastObject];
}

- (NSManagedObjectID*) objectIDWithBackingObject:(NSManagedObject*) object {
	CDRecord* record = [object valueForKey:@"CDRecord"];
	return [self.store newObjectIDForEntity:self.store.entities[object.entity.name] referenceObject:record.recordID];
}

@end
