//
//  CDPushOperation.m
//  CloudData
//
//  Created by Artem Shimanski on 10.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "CDPushOperation.h"
#import "CDCloudStore.h"
#import "CDCloudStore+Protected.h"
#import "CKRecord+CD.h"

@implementation CDPushOperation {
	CDCloudStore* _store;
	void(^_completion)(NSError* error, NSArray<CKRecord*>* conflicts);
	NSManagedObjectContext* _backingManagedObjectContext;
	CKModifyRecordsOperation* _databaseOperation;
	NSMutableDictionary<CKRecordID*, CDRecord*>* _cache;
	//NSDictionary<CKRecordID*, NSArray<CDTransaction*>*>* _transactions;
}

- (instancetype) initWithStore:(CDCloudStore*) store completionHandler:(void(^)(NSError* error, NSArray<CKRecord*>* conflicts)) block {
	if (self = [super init]) {
		_store = store;
		_completion = [block copy];
		_backingManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
		_backingManagedObjectContext.persistentStoreCoordinator = _store.backingPersistentStoreCoordinator;
		_backingManagedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
	}
	return self;
}

- (void) main {
	[_backingManagedObjectContext performBlock:^{
		[self prepareDatabaseOperation];
		if (_databaseOperation) {
			dispatch_group_t dispatchGroup = dispatch_group_create();
			
			NSMutableArray* conflicts = [NSMutableArray new];
			_databaseOperation.perRecordCompletionBlock = ^(CKRecord * _Nullable record, NSError * _Nullable error) {
				if (error) {
					if ([error.domain isEqualToString:CKErrorDomain]) {
						switch (error.code) {
							case CKErrorServerRecordChanged:
								[conflicts addObject:record];
								break;
							case CKErrorNetworkUnavailable:
							case CKErrorNetworkFailure:
							case CKErrorServiceUnavailable:
							case CKErrorRequestRateLimited:
								break;
							default:
								NSLog(@"%@", error);
								dispatch_group_enter(dispatchGroup);
								[_backingManagedObjectContext performBlock:^{
									CDRecord* cdRecord = _cache[record.recordID];
									cdRecord.cache.version = cdRecord.version;
									dispatch_group_leave(dispatchGroup);
								}];
								break;
						}
					}
				}
				else {
					dispatch_group_enter(dispatchGroup);
					[_backingManagedObjectContext performBlock:^{
						CDRecord* cdRecord = _cache[record.recordID];
						cdRecord.cache.cachedRecord = record;
						cdRecord.cache.version = cdRecord.version;
						dispatch_group_leave(dispatchGroup);
					}];
				}
			};
			
			_databaseOperation.modifyRecordsCompletionBlock = ^(NSArray<CKRecord *> * _Nullable savedRecords, NSArray<CKRecordID *> * _Nullable deletedRecordIDs, NSError * _Nullable operationError) {
				dispatch_group_notify(dispatchGroup, dispatch_get_main_queue(), ^{
					[_backingManagedObjectContext performBlock:^{
						for (CKRecordID* recordID in deletedRecordIDs) {
							CDRecord* cdRecord = _cache[recordID];
							[_backingManagedObjectContext deleteObject:cdRecord];
						}
						if ([_backingManagedObjectContext hasChanges])
							[_backingManagedObjectContext save:nil];
						
						_completion(operationError, conflicts.count > 0 ? conflicts : nil);
						[self finishWithError:operationError];
					}];
				});
			};
			[_store.database addOperation:_databaseOperation];
		}
		else {
			if ([_backingManagedObjectContext hasChanges])
				[_backingManagedObjectContext save:nil];
			[self finishWithError:nil];
		}
	}];
	
	/*[_backingManagedObjectContext performBlock:^{
		[self prepareDatabaseOperation];
		if (_databaseOperation) {
			dispatch_group_t dispatchGroup = dispatch_group_create();
			
			NSMutableArray* conflicts = [NSMutableArray new];
			_databaseOperation.perRecordCompletionBlock = ^(CKRecord * _Nullable record, NSError * _Nullable error) {
				NSArray<CDTransaction*>* array = _transactions[record.recordID];
				if (array.count == 0)
					return;
				if (error) {
					if ([error.domain isEqualToString:CKErrorDomain]) {
						switch (error.code) {
							case CKErrorServerRecordChanged:
								[conflicts addObject:record];
								break;
							case CKErrorNetworkUnavailable:
							case CKErrorNetworkFailure:
							case CKErrorServiceUnavailable:
							case CKErrorRequestRateLimited:
								break;
							default:
								NSLog(@"%@", error);
								dispatch_group_enter(dispatchGroup);
								[_backingManagedObjectContext performBlock:^{
									for (CDTransaction* transaction in array)
										[_backingManagedObjectContext deleteObject:transaction];
									dispatch_group_leave(dispatchGroup);
								}];
								break;
						}
					}
				}
				else {
					dispatch_group_enter(dispatchGroup);
					[_backingManagedObjectContext performBlock:^{
						CDRecord* cdRecord = array[0].record;
						cdRecord.record = record;
						for (CDTransaction* transaction in array)
							[_backingManagedObjectContext deleteObject:transaction];
						dispatch_group_leave(dispatchGroup);
					}];
				}
			};
			
			_databaseOperation.modifyRecordsCompletionBlock = ^(NSArray<CKRecord *> * _Nullable savedRecords, NSArray<CKRecordID *> * _Nullable deletedRecordIDs, NSError * _Nullable operationError) {
				dispatch_group_notify(dispatchGroup, dispatch_get_main_queue(), ^{
					[_backingManagedObjectContext performBlock:^{
						for (CKRecordID* recordID in deletedRecordIDs) {
							NSArray<CDTransaction*>* array = _transactions[recordID];
							if (array.count == 0)
								continue;
							CDRecord* cdRecord = array[0].record;
							[_backingManagedObjectContext deleteObject:cdRecord];
						}
						if ([_backingManagedObjectContext hasChanges])
							[_backingManagedObjectContext save:nil];
						
						_completion(operationError, conflicts.count > 0 ? conflicts : nil);
						[self finishWithError:operationError];
					}];
				});
			};
			[_store.database addOperation:_databaseOperation];
		}
		else {
			if ([_backingManagedObjectContext hasChanges])
				[_backingManagedObjectContext save:nil];
			[self finishWithError:nil];
		}
	}];*/
}

- (void) prepareDatabaseOperation {
	NSFetchRequest* request = [NSFetchRequest fetchRequestWithEntityName:@"CDRecord"];
	request.predicate = [NSPredicate predicateWithFormat:@"version > cache.version OR version == 0"];
	//request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"record.recordID" ascending:YES], [NSSortDescriptor sortDescriptorWithKey:@"version" ascending:YES]];
	
	NSMutableArray<CKRecord*>* recordsToSave = [NSMutableArray new];
	NSMutableArray<CKRecordID*>* recordsToDelete = [NSMutableArray new];
	NSMutableDictionary* cache = [NSMutableDictionary new];
	for (CDRecord* record in [_backingManagedObjectContext executeFetchRequest:request error:nil]) {
		if (record.version == 0 && record.cache.version > 0) {
			cache[record.cache.cachedRecord.recordID] = record;
			[recordsToDelete addObject:record.cache.cachedRecord.recordID];
		}
		else {
			NSManagedObject* backingObject = [record valueForKey:record.recordType];
			NSDictionary* changedValues = [record.cache.cachedRecord changedValuesWithObject:backingObject];
			if (changedValues.count > 0) {
				cache[record.cache.cachedRecord.recordID] = record;
				CKRecord* ckRecord = [record.cache.cachedRecord copy];
				[changedValues enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
					ckRecord[key] = obj;
				}];
				[recordsToSave addObject:ckRecord];
			}
		}
	}
	
	if (recordsToSave.count > 0 || recordsToDelete.count > 0) {
		_databaseOperation = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:recordsToSave recordIDsToDelete:recordsToDelete];
		_cache = cache;
}
	
	/*NSFetchedResultsController* results = [[NSFetchedResultsController alloc] initWithFetchRequest:request managedObjectContext:_backingManagedObjectContext sectionNameKeyPath:@"record.recordID" cacheName:nil];
	[results performFetch:nil];
	
	NSMutableDictionary<CKRecordID*, CKRecord*>* recordsToSave = [NSMutableDictionary new];
	NSMutableDictionary<CKRecordID*, CDRecord*>* recordsToDelete = [NSMutableDictionary new];
	
	CKRecordZoneID* recordZoneID = _store.recordZoneID;
	
	for (id<NSFetchedResultsSectionInfo> section in results.sections) {
		NSArray<CDTransaction*>* objects = [section objects];
		CDRecord* cdRecord = [objects[0] record];
		if (!cdRecord) {
			for (CDTransaction* transaction in objects)
				[_backingManagedObjectContext deleteObject:transaction];
			continue;
		}
		CKRecord* ckRecord = [cdRecord.record copy];
		CKRecordID* recordID = ckRecord.recordID;
		
		if (!recordID) {
			[_backingManagedObjectContext deleteObject:cdRecord];
			continue;
		}
		
		NSManagedObject* object = [cdRecord valueForKey:cdRecord.recordType];
		NSDictionary* properties = object.entity.propertiesByName;
		
		BOOL isDeleted = NO;
		NSMutableArray* transactions = [NSMutableArray new];
		
		for (CDTransaction* transaction in objects) {
			if (isDeleted)
				continue;
			
			if (transaction.action == CDTransactionActionChange) {
				NSPropertyDescription* property = properties[transaction.key];
				if ([property isKindOfClass:[NSAttributeDescription class]]) {
					ckRecord[transaction.key] = (id) transaction.value;
				}
				else if ([property isKindOfClass:[NSRelationshipDescription class]]) {
					NSRelationshipDescription* relationship = (NSRelationshipDescription*) property;
					CKReferenceAction action = relationship.inverseRelationship.deleteRule == NSCascadeDeleteRule ? CKReferenceActionDeleteSelf : CKReferenceActionNone;
					
					id value = transaction.value;
					if ([value isKindOfClass:[NSSet class]]) {
						NSMutableArray* array = [NSMutableArray new];
						for (NSString* recordID in value)
							[array addObject:[[CKReference alloc] initWithRecordID:[[CKRecordID alloc] initWithRecordName:recordID zoneID:recordZoneID] action:action]];
						value = array;
					}
					else if ([value isKindOfClass:[NSString class]]) {
						value = [[CKReference alloc] initWithRecordID:[[CKRecordID alloc] initWithRecordName:value zoneID:recordZoneID] action:action];
					}
					else
						value = nil;
					ckRecord[transaction.key] = value;
				}
			}
			else if (transaction.action == CDTransactionActionDelete) {
				recordsToDelete[recordID] = cdRecord;
				isDeleted = YES;
				break;
			}
			[transactions addObject:transaction];
		}
		transactionsMap[recordID] = transactions;
		
		if (!isDeleted)
			recordsToSave[recordID] = ckRecord;
	}
	
	if (recordsToSave.count > 0 || recordsToDelete.count > 0) {
		_databaseOperation = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:[recordsToSave allValues] recordIDsToDelete:[recordsToDelete allKeys]];
		_transactions = transactionsMap;
	}*/
}

@end
