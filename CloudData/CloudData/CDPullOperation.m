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
#import "CDBrokenReference+CoreDataClass.h"
#import <objc/runtime.h>

@implementation CDPullOperation {
	CDCloudStore* _store;
	void(^_completion)(BOOL moreComing, NSError* error);
	NSManagedObjectContext* _backingManagedObjectContext;
	NSManagedObjectContext* _workManagedObjectContext;
	NSDictionary<NSString *, NSEntityDescription *>* _entitiesByName;
	CDBackingObjectHelper* _backingObjectHelper;
}

- (instancetype) initWithStore:(CDCloudStore*) store completionHandler:(void(^)(BOOL moreComing, NSError* error)) block {
	if (self = [super init]) {
		_store = store;
		_completion = [block copy];
		_backingManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
		_backingManagedObjectContext.parentContext = _store.backingManagedObjectContext;
		_workManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
		_workManagedObjectContext.persistentStoreCoordinator = _store.persistentStoreCoordinator;
		_workManagedObjectContext.mergePolicy = _store.mergePolicy;
		_backingObjectHelper = [[CDBackingObjectHelper alloc] initWithStore:_store managedObjectContext:_backingManagedObjectContext];
	}
	return self;
}

- (void) main {
	_entitiesByName = _workManagedObjectContext.persistentStoreCoordinator.managedObjectModel.entitiesByName;
	
	[_backingManagedObjectContext performBlock:^{
		NSFetchRequest* request = [NSFetchRequest fetchRequestWithEntityName:@"CDMetadata"];
		CDMetadata* metadata = [[_backingManagedObjectContext executeFetchRequest:request error:nil] lastObject];
		if (!metadata)
			metadata = [NSEntityDescription insertNewObjectForEntityForName:@"CDMetadata" inManagedObjectContext:_backingManagedObjectContext];
		
		__block CKFetchRecordChangesOperation* fetchOperation = [[CKFetchRecordChangesOperation alloc] initWithRecordZoneID:_store.recordZoneID previousServerChangeToken:metadata.serverChangeToken];
		
		dispatch_group_t dispatchGroup = dispatch_group_create();
		
		NSMutableArray* changedRecords = [NSMutableArray new];
		NSMutableArray* deletedRecordIDs = [NSMutableArray new];
		fetchOperation.recordChangedBlock = ^(CKRecord *record) {
			if (_entitiesByName[record.recordType])
				[changedRecords addObject:record];
		};
		
		fetchOperation.recordWithIDWasDeletedBlock = ^(CKRecordID *recordID) {
			[deletedRecordIDs addObject:recordID];
		};
		
		fetchOperation.fetchRecordChangesCompletionBlock = ^(CKServerChangeToken * _Nullable serverChangeToken, NSData * _Nullable clientChangeTokenData, NSError * _Nullable operationError) {
			if (!operationError) {
				[self saveRecords:changedRecords completionHandler:^{
					[self deleteRecordsWithIDs:deletedRecordIDs completionHandler:^{
						[_backingManagedObjectContext performBlock:^{
							metadata.serverChangeToken = serverChangeToken;
							[_backingManagedObjectContext save:nil];
							[_workManagedObjectContext performBlock:^{
								if ([_workManagedObjectContext hasChanges])
									[_workManagedObjectContext save:nil];
								[self finishWithError:operationError];
								_completion(fetchOperation.moreComing, operationError);
								fetchOperation = nil;
							}];
						}];
					}];
				}];
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

- (void) saveRecords:(NSArray<CKRecord*>*) records completionHandler:(void(^)()) block {
	
	[_backingManagedObjectContext performBlock:^{
		NSString* recordIDs = [records valueForKeyPath:@"recordID.recordName"];
		NSFetchRequest* request = [NSFetchRequest fetchRequestWithEntityName:@"CDBrokenReference"];
		request.predicate = [NSPredicate predicateWithFormat:@"to IN %@", recordIDs];

		NSMutableArray* restoredReferences = [NSMutableArray new];
		
		NSMutableDictionary* cache = [NSMutableDictionary new];
		for (CDBrokenReference* reference in [_backingManagedObjectContext executeFetchRequest:request error:nil]) {
			NSManagedObject* from = cache[reference.from];
			if (!from) {
				from =  [_backingObjectHelper backingObjectWithRecordID:reference.from];
				if (from)
					cache[reference.from] = from;
			}
			
			if (from)
				[restoredReferences addObject:@{@"from":[_backingObjectHelper objectIDWithBackingObject:from], @"to":reference.to, @"name":reference.name}];
			[_backingManagedObjectContext deleteObject:reference];
		}
		
		
		[_workManagedObjectContext performBlock:^{
			NSMutableDictionary<NSString*, NSManagedObject*>* objectsMap = [NSMutableDictionary new];
			for (CKRecord* record in records) {
				NSManagedObjectID* objectID = [_store newObjectIDForEntity:_entitiesByName[record.recordType] referenceObject:record.recordID.recordName];
				NSManagedObject* object = [_workManagedObjectContext existingObjectWithID:objectID error:nil];
				if (!object) {
					object = [NSEntityDescription insertNewObjectForEntityForName:record.recordType inManagedObjectContext:_workManagedObjectContext];
				}
				objectsMap[record.recordID.recordName] = object;
				objc_setAssociatedObject(object, @"CKRecord", record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			}
			
			for (NSDictionary* reference in restoredReferences) {
				NSManagedObject* from = [_workManagedObjectContext existingObjectWithID:reference[@"from"] error:nil];
				NSManagedObject* to = objectsMap[reference[@"to"]];
				NSString* name = reference[@"name"];
				NSRelationshipDescription* relationship = from.entity.relationshipsByName[name];
				if (relationship.toMany) {
					[[from mutableSetValueForKey:relationship.name] addObject:to];
				}
				else
					[from setValue:to forKey:name];
			}
			
			NSMutableArray* brokenReferences = [NSMutableArray new];
			for (CKRecord* record in records) {
				NSManagedObject* object = objectsMap[record.recordID.recordName];
				for (NSPropertyDescription* property in object.entity.properties) {
					if ([property isKindOfClass:[NSAttributeDescription class]]) {
						NSAttributeDescription* attribute = (NSAttributeDescription*) property;
						id value = [attribute reverseTransformValue:record[attribute.name]];
						[object setValue:value forKey:attribute.name];
					}
					else if ([property isKindOfClass:[NSRelationshipDescription class]]) {
						NSRelationshipDescription* relationship = (NSRelationshipDescription*) property;
						if ([relationship shouldSerialize]) {
							id value = record[relationship.name];
							if ([value isKindOfClass:[CKReference class]])
								value = @[value];
							else if ([value isKindOfClass:[NSArray class]]) {
								if (!relationship.toMany && [value count] > 0)
									value = @[[value lastObject]];
							}
							else
								value = nil;
							
							NSMutableSet* references = [NSMutableSet new];
							NSMutableSet* broken = [NSMutableSet new];
							for (CKReference* reference in value) {
								if ([reference isKindOfClass:[CKReference class]]) {
									NSManagedObject* referenceObject = objectsMap[reference.recordID.recordName];
									if (!referenceObject)
										referenceObject = [_workManagedObjectContext existingObjectWithID:[_store newObjectIDForEntity:relationship.destinationEntity referenceObject:reference.recordID.recordName] error:nil];
									if (referenceObject)
										[references addObject:referenceObject];
									else
										[brokenReferences addObject:@{@"name":relationship.name, @"from":record.recordID.recordName, @"to":reference.recordID.recordName}];
								}
								else {
									NSLog(@"Invalid reference %@", value);
									value = nil;
								}
							}
							if (relationship.toMany)
								[object setValue:references forKey:relationship.name];
							else
								[object setValue:[references anyObject] forKey:relationship.name];
						}

					}
				}
			}
			
			[_backingManagedObjectContext performBlock:^{
				for (NSDictionary* reference in brokenReferences) {
					CDBrokenReference* r = [NSEntityDescription insertNewObjectForEntityForName:@"CDBrokenReference" inManagedObjectContext:_backingManagedObjectContext];
					r.name = reference[@"name"];
					r.from = reference[@"from"];
					r.to = reference[@"to"];
				}
				
				block();
			}];
		}];
		
	}];
}

- (void) deleteRecordsWithIDs:(NSArray<CKRecordID*>*) recordIDs completionHandler:(void(^)()) block {
	[_backingManagedObjectContext performBlock:^{
		NSMutableArray* deletedObjectIDs = [NSMutableArray new];
		for (CKRecordID* recordID in recordIDs) {
			NSManagedObject* object = [_backingObjectHelper backingObjectWithRecordID:recordID.recordName];
			if (object) {
				NSManagedObjectID* objectID = [_backingObjectHelper objectIDWithBackingObject:object];
				[deletedObjectIDs addObject:objectID];
			}
		}
		[_workManagedObjectContext performBlock:^{
			for (NSManagedObjectID* objectID in deletedObjectIDs) {
				NSManagedObject* object = [_workManagedObjectContext existingObjectWithID:objectID error:nil];
				if (object)
					[_workManagedObjectContext deleteObject:object];
			}
			block();
		}];
	}];
}

@end
