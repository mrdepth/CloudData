//
//  CDPullOperation.m
//  CloudData
//
//  Created by Artem Shimanski on 10.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "CDPullOperation.h"
#import "CDCloudStore.h"
#import "CDCloudStore+Protected.h"
#import "CDMetadata+CoreDataClass.h"
#import "CDManagedObjectContext.h"
#import <objc/runtime.h>

@implementation CDPullOperation {
	CDCloudStore* _store;
	void(^_completion)(BOOL moreComing, NSError* error);
	NSManagedObjectContext* _backingManagedObjectContext;
	CDManagedObjectContext* _workManagedObjectContext;
	NSDictionary<NSString *, NSEntityDescription *>* _entitiesByName;
	CDBackingObjectHelper* _backingObjectHelper;
	NSMutableDictionary<NSManagedObjectID*, NSManagedObject*>* _cache;
}

- (instancetype) initWithStore:(CDCloudStore*) store completionHandler:(void(^)(BOOL moreComing, NSError* error)) block {
	if (self = [super init]) {
		_store = store;
		_completion = [block copy];
		_backingManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
		_backingManagedObjectContext.parentContext = _store.backingManagedObjectContext;
		_workManagedObjectContext = [[CDManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
		_workManagedObjectContext.persistentStoreCoordinator = _store.persistentStoreCoordinator;
		_workManagedObjectContext.mergePolicy = _store.mergePolicy;
		_backingObjectHelper = [[CDBackingObjectHelper alloc] initWithStore:_store managedObjectContext:_backingManagedObjectContext];
	}
	return self;
}

- (void) main {
	_entitiesByName = _workManagedObjectContext.persistentStoreCoordinator.managedObjectModel.entitiesByName;
	_cache = [NSMutableDictionary new];
	
	[_backingManagedObjectContext performBlock:^{
		NSFetchRequest* request = [NSFetchRequest fetchRequestWithEntityName:@"CDMetadata"];
		CDMetadata* metadata = [[_backingManagedObjectContext executeFetchRequest:request error:nil] lastObject];
		if (!metadata)
			metadata = [NSEntityDescription insertNewObjectForEntityForName:@"CDMetadata" inManagedObjectContext:_backingManagedObjectContext];
		
		__block CKFetchRecordChangesOperation* fetchOperation = [[CKFetchRecordChangesOperation alloc] initWithRecordZoneID:_store.recordZoneID previousServerChangeToken:metadata.serverChangeToken];
		
		dispatch_group_t dispatchGroup = dispatch_group_create();
		
		fetchOperation.recordChangedBlock = ^(CKRecord *record) {
			if (_entitiesByName[record.recordType]) {
				dispatch_group_enter(dispatchGroup);
				[self saveRecord:record completionHandler:^{
					dispatch_group_leave(dispatchGroup);
				}];
			}
		};
		
		fetchOperation.recordWithIDWasDeletedBlock = ^(CKRecordID *recordID) {
			dispatch_group_enter(dispatchGroup);
			[self deleteRecordWithID:recordID completionHandler:^{
				dispatch_group_leave(dispatchGroup);
			}];
		};
		
		fetchOperation.fetchRecordChangesCompletionBlock = ^(CKServerChangeToken * _Nullable serverChangeToken, NSData * _Nullable clientChangeTokenData, NSError * _Nullable operationError) {
			if (!operationError) {
				dispatch_group_notify(dispatchGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
					@autoreleasepool {
						[_backingManagedObjectContext performBlock:^{
							metadata.serverChangeToken = serverChangeToken;
							[_backingManagedObjectContext save:nil];
							[_workManagedObjectContext performBlock:^{
								NSError* error = nil;
								if ([_workManagedObjectContext hasChanges])
									[_workManagedObjectContext save:&error];
								[self finishWithError:operationError];
								_completion(fetchOperation.moreComing, operationError);
								fetchOperation = nil;
							}];
						}];
					}
				});
			}
			else {
				[self finishWithError:operationError];
				_completion(fetchOperation.moreComing, operationError);
				fetchOperation = nil;
			}
		};
		[_store.database addOperation:fetchOperation];
	}];
}

- (void) saveRecord:(CKRecord*) record completionHandler:(void(^)()) block {
	NSParameterAssert(record != nil);
	
	[_workManagedObjectContext performBlock:^{
		NSManagedObject* (^get)(NSManagedObjectID*) = ^(NSManagedObjectID* objectID) {
			@synchronized (_cache) {
				NSManagedObject* object = _cache[objectID] ?: [_workManagedObjectContext cachedObjectWithID:objectID error:nil];
				if (!object) {
					object = [NSEntityDescription insertNewObjectForEntityForName:objectID.entity.name inManagedObjectContext:_workManagedObjectContext];
					_cache[objectID] = object;
				}
				return object;
			}
		};
		
		NSManagedObjectID* objectID = [_backingObjectHelper objectIDWithRecordID:record.recordID.recordName entityName:record.recordType];
		NSManagedObject* object = get(objectID);
		objc_setAssociatedObject(object, @"CKRecord", record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		
		
		for (NSPropertyDescription* property in object.entity.properties) {
			if ([property isKindOfClass:[NSAttributeDescription class]]) {
				NSAttributeDescription* attribute = (NSAttributeDescription*) property;
				[object setValue:[attribute managedValueFromCKRecord:record] forKey:attribute.name];
			}
			else if ([property isKindOfClass:[NSRelationshipDescription class]]) {
				NSRelationshipDescription* relationship = (NSRelationshipDescription*) property;
				if ([relationship shouldSerialize]) {
					id value = record[relationship.name];
					if (relationship.toMany) {
						if ([value isKindOfClass:[CKReference class]])
							value = @[value];
						if ([value isKindOfClass:[NSArray class]]) {
							NSMutableSet* set = [NSMutableSet new];
							for (CKReference* reference in value) {
								NSManagedObjectID* objectID = [relationship managedReferenceFromCKReference:reference inStore:_store];
								NSManagedObject* referenceObject = objectID ? get(objectID) : nil;
								if (referenceObject) {
									if (!objc_getAssociatedObject(referenceObject, @"CKRecord"))
										objc_setAssociatedObject(referenceObject, @"CKRecord", [[CKRecord alloc] initWithRecordType:relationship.destinationEntity.name recordID:reference.recordID], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
									[set addObject:referenceObject];
								}
							}
							[object setValue:set forKey:relationship.name];
						}
					}
					else {
						CKReference* reference = value;
						NSManagedObjectID* objectID = reference ? [relationship managedReferenceFromCKReference:reference inStore:_store] : nil;
						NSManagedObject* referenceObject = objectID ? get(objectID) : nil;
						if (referenceObject) {
							if (!objc_getAssociatedObject(referenceObject, @"CKRecord"))
								objc_setAssociatedObject(referenceObject, @"CKRecord", [[CKRecord alloc] initWithRecordType:relationship.destinationEntity.name recordID:reference.recordID], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
						}
						[object setValue:referenceObject forKey:relationship.name];
					}
				}
			}
		}
		block();
	}];
}

- (void) deleteRecordWithID:(CKRecordID*) recordID completionHandler:(void(^)()) block {
	[_backingManagedObjectContext performBlock:^{
		NSLog(@"%@", recordID);
		NSManagedObject* object = [_backingObjectHelper backingObjectWithRecordID:recordID.recordName];
		if (object) {
			NSManagedObjectID* objectID = [_backingObjectHelper objectIDWithBackingObject:object];
			[_workManagedObjectContext performBlock:^{
				NSManagedObject* object = [_workManagedObjectContext cachedObjectWithID:objectID error:nil];
				objc_setAssociatedObject(object, @"CKRecordID", recordID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
				if (object)
					[_workManagedObjectContext deleteObject:object];
				block();
			}];
		}
		else
			block();
	}];
}

@end
