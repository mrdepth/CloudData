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
			_completion(nil, nil);
		}
	}];
}

- (void) prepareDatabaseOperation {
	NSFetchRequest* request = [NSFetchRequest fetchRequestWithEntityName:@"CDRecord"];
	request.predicate = [NSPredicate predicateWithFormat:@"version > cache.version OR version == 0"];
	
	NSMutableArray<CKRecord*>* recordsToSave = [NSMutableArray new];
	NSMutableArray<CKRecordID*>* recordsToDelete = [NSMutableArray new];
	NSMutableDictionary* cache = [NSMutableDictionary new];
	for (CDRecord* record in [_backingManagedObjectContext executeFetchRequest:request error:nil]) {
		if (record.version == 0) {
			if (record.cache.version > 0) {
				cache[record.cache.cachedRecord.recordID] = record;
				[recordsToDelete addObject:record.cache.cachedRecord.recordID];
			}
			else
				[_backingManagedObjectContext deleteObject:record];
		}
		else {
			NSManagedObject* backingObject = [record valueForKey:record.recordType];
			NSDictionary* changedValues = [record.cache.cachedRecord changedValuesWithObject:backingObject entity:_store.entities[backingObject.entity.name]];
			if (changedValues.count > 0) {
				cache[record.cache.cachedRecord.recordID] = record;
				CKRecord* ckRecord = [record.cache.cachedRecord copy];
				[changedValues enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
					ckRecord[key] = [obj isKindOfClass:[NSNull class]] ? nil : obj;
				}];
				[recordsToSave addObject:ckRecord];
			}
			else
				record.cache.version = record.version;
		}
	}
	
	if (recordsToSave.count > 0 || recordsToDelete.count > 0) {
		_databaseOperation = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:recordsToSave recordIDsToDelete:recordsToDelete];
		_cache = cache;
	}
}

@end
