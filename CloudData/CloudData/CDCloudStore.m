//
//  CDCloudStore.m
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "CDCloudStore.h"
#import "NSUUID+CD.h"
#import <objc/runtime.h>
#import "CDCloudStore+Protected.h"
#import "CDPushOperation.h"
#import "CDPullOperation.h"


NSString * const CDCloudStoreType = @"CDCloudStore";

NSString * const CDCloudStoreOptionContainerIdentifierKey = @"CDCloudStoreOptionContainerIdentifierKey";
NSString * const CDCloudStoreOptionDatabaseScopeKey = @"CDCloudStoreOptionDatabaseScopeKey";
NSString * const CDCloudStoreOptionRecordZoneKey = @"CDCloudStoreOptionRecordZoneKey";
NSString * const CDCloudStoreOptionMergePolicyType = @"CDCloudStoreOptionMergePolicyType";

NSString * const CDDidReceiveRemoteNotification = @"CDDidReceiveRemoteNotification";

NSString * const CDSubscriptionID = @"autoUpdate";

@interface CDCloudStore()
@property (nonatomic, assign, getter = isPushing) BOOL pushing;
@property (nonatomic, assign, getter = isPulling) BOOL pulling;

@end

@implementation CDCloudStore

- (id) initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)root configurationName:(NSString *)name URL:(NSURL *)url options:(NSDictionary *)options {
	if (self = [super initWithPersistentStoreCoordinator:root configurationName:name URL:url options:options]) {
		self.operationQueue = [CDOperationQueue new];
	}
	return self;
}

- (void) dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)loadMetadata:(NSError **)error {
	if (!self.backingPersistentStoreCoordinator) {
		self.entities = self.persistentStoreCoordinator.managedObjectModel.entitiesByName;
		self.backingManagedObjectModel = [self createBackingModelFromSourceModel:self.persistentStoreCoordinator.managedObjectModel];
		_backingPersistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:_backingManagedObjectModel];
		[self loadBackingStoreWithError:error];
		
		if (self.backingPersistentStore) {
			self.backingManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
			self.backingManagedObjectContext.persistentStoreCoordinator = _backingPersistentStoreCoordinator;
			self.backingObjectsHelper = [[CDBackingObjectHelper alloc] initWithStore:self managedObjectContext:self.backingManagedObjectContext];
			
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(managedObjectContextDidSave:) name:NSManagedObjectContextDidSaveNotification object:nil];
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ubiquityIdentityDidChange:) name:NSUbiquityIdentityDidChangeNotification object:nil];
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveRemoteNotification:) name:CDDidReceiveRemoteNotification object:nil];
			return YES;
		}
		else
			return NO;
	}
	return YES;
}

- (nullable id)executeRequest:(NSPersistentStoreRequest *)request withContext:(nullable NSManagedObjectContext*)context error:(NSError **)error {
	if (request.requestType == NSSaveRequestType)
		return [self executeSaveRequest:(NSSaveChangesRequest*) request withContext:context error:error];
	else if (request.requestType == NSFetchRequestType)
		return [self executeFetchRequest:(NSFetchRequest*) request withContext:context error:error];
	return nil;
}

- (nullable NSArray<NSManagedObjectID *> *)obtainPermanentIDsForObjects:(NSArray<NSManagedObject *> *)array error:(NSError **)error {
	NSMutableArray* result = [NSMutableArray new];
	[_backingManagedObjectContext performBlockAndWait:^{
		NSMutableDictionary* backingObjects = [NSMutableDictionary new];
		for (NSManagedObject* object in array) {
			CKRecord* record = objc_getAssociatedObject(object, @"CKRecord");
			CDRecord* cdRecord = [NSEntityDescription insertNewObjectForEntityForName:@"CDRecord" inManagedObjectContext:_backingManagedObjectContext];
			cdRecord.recordType = object.entity.name;
			cdRecord.record = record ?: [[CKRecord alloc] initWithRecordType:cdRecord.recordType zoneID:self.recordZoneID];
			cdRecord.recordID = cdRecord.record.recordID.recordName;
			[result addObject:[self newObjectIDForEntity:object.entity referenceObject:cdRecord.recordID]];
		}
	}];
	
	return result;
}

- (nullable NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID*)objectID withContext:(NSManagedObjectContext*)context error:(NSError**)error {
	__block NSMutableDictionary* values = nil;
	
	__block int64_t version = 0;
	[_backingManagedObjectContext performBlockAndWait:^{
		NSManagedObject* backingObject = [self.backingObjectsHelper backingObjectWithObjectID:objectID];
		if (!backingObject)
			return;
		values = [NSMutableDictionary new];
		NSEntityDescription* entity = _entities[backingObject.entity.name];
		for (NSString* key in entity.attributesByName.allKeys) {
			id obj = [backingObject valueForKey:key];
			if (obj)
				values[key] = obj;
		}
		[entity.relationshipsByName enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, NSRelationshipDescription * _Nonnull obj, BOOL * _Nonnull stop) {
			if (!obj.toMany) {
				NSManagedObject* reference = [backingObject valueForKey:key];
				if (reference)
					values[key] = [self.backingObjectsHelper objectIDWithBackingObject:reference];
				else
					values[key] = [NSNull null];
			}
		}];

		CDRecord* record = [backingObject valueForKey:@"CDRecord"];
		version = record.version;
	}];
	return values ? [[NSIncrementalStoreNode alloc] initWithObjectID:objectID withValues:values version:version] : nil;
}

- (nullable id)newValueForRelationship:(NSRelationshipDescription*)relationship forObjectWithID:(NSManagedObjectID*)objectID withContext:(nullable NSManagedObjectContext *)context error:(NSError **)error {
	__block id result = nil;
	[_backingManagedObjectContext performBlockAndWait:^{
		NSManagedObject* backingObject = [self.backingObjectsHelper backingObjectWithObjectID:objectID];
		if (!backingObject)
			return;
		if (relationship.toMany) {
			NSMutableSet* set = [NSMutableSet new];
			for (NSManagedObject* object in [backingObject valueForKey:relationship.name])
				[set addObject:[self.backingObjectsHelper objectIDWithBackingObject:object]];
			result = set;
		}
		else {
			NSManagedObject* object = [backingObject valueForKey:relationship.name];
			result = object ? [self.backingObjectsHelper objectIDWithBackingObject:object] : [NSNull null];
		}
	}];
	return result;
}

#pragma mark - Loading

- (NSManagedObjectModel*) createBackingModelFromSourceModel:(NSManagedObjectModel*) model {
	NSManagedObjectModel* cloudDataObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:[[NSBundle bundleForClass:self.class] URLForResource:@"CloudData" withExtension:@"momd"]];
	
	NSManagedObjectModel* backingModel = [NSManagedObjectModel modelByMergingModels:@[model, cloudDataObjectModel]];
	
	NSEntityDescription* recordEntity = backingModel.entitiesByName[@"CDRecord"];
	NSMutableArray* properties = [recordEntity.properties mutableCopy];
	for (NSEntityDescription* entity in model) {
		NSRelationshipDescription* relationship = [NSRelationshipDescription new];
		relationship.name = entity.name;
		relationship.maxCount = 1;
		relationship.deleteRule = NSCascadeDeleteRule;
		relationship.optional = YES;
		relationship.destinationEntity = backingModel.entitiesByName[entity.name];
		[properties addObject:relationship];
		
		NSRelationshipDescription* inverseRelationship = [NSRelationshipDescription new];
		inverseRelationship.name = @"CDRecord";
		inverseRelationship.deleteRule = NSNullifyDeleteRule;
		inverseRelationship.maxCount = 1;
		inverseRelationship.optional = NO;
		inverseRelationship.destinationEntity = recordEntity;
		
		relationship.inverseRelationship = inverseRelationship;
		relationship.destinationEntity.properties = [relationship.destinationEntity.properties arrayByAddingObject:inverseRelationship];
	}
	recordEntity.properties = properties;
	
	return backingModel;
}

- (BOOL) loadBackingStoreWithError:(NSError **)error {
	id value = self.options[CDCloudStoreOptionDatabaseScopeKey];
	id zone = self.options[CDCloudStoreOptionRecordZoneKey] ?: [[self.URL lastPathComponent] stringByDeletingPathExtension];
	id mergePolicyType = self.options[CDCloudStoreOptionMergePolicyType] ?: @(NSMergeByPropertyObjectTrumpMergePolicyType);
	NSAssert([mergePolicyType integerValue] != NSErrorMergePolicyType, @"NSErrorMergePolicyType in not supported");
	self.mergePolicy = [[NSMergePolicy alloc] initWithMergeType:[mergePolicyType integerValue]];
	
	
	NSString* owner = floor(NSFoundationVersionNumber) <= NSFoundationVersionNumber_iOS_9_x_Max ? CKOwnerDefaultName : CKCurrentUserDefaultName;
	self.recordZoneID = [[CKRecordZoneID alloc] initWithZoneName:zone ownerName:owner];
	
	NSString* containerIdentifier = self.options[CDCloudStoreOptionContainerIdentifierKey];
	self.databaseScope = value ? [value integerValue] : CKDatabaseScopePrivate;
	
	id token = [[NSFileManager defaultManager] ubiquityIdentityToken];
	self.ubiquityIdentityToken = token;
	
	NSString* identifier;
	if (self.databaseScope == CKDatabaseScopePrivate && token)
		identifier = [NSUUID UUIDWithUbiquityIdentityToken:token].UUIDString;
	else
		identifier = @"local";
	NSURL* url = [self.URL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@/%@.sqlite", identifier, containerIdentifier, self.recordZoneID.zoneName]];

	[[NSFileManager defaultManager] createDirectoryAtPath:[url.path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:error];
	
	self.backingPersistentStore = [_backingPersistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:url options:@{} error:error];
	
	self.accountStatus = CKAccountStatusCouldNotDetermine;
	if (self.backingPersistentStore && (self.databaseScope == CKDatabaseScopePublic || token)) {
		self.container = containerIdentifier ? [CKContainer containerWithIdentifier:containerIdentifier] : [CKContainer defaultContainer];
		[self loadDatabase];
		return YES;
	}
	else {
		self.database = nil;
		return NO;
	}
	
	return self.backingPersistentStore != nil;
}

- (void) loadDatabase {
	if ([self.container respondsToSelector:@selector(databaseWithDatabaseScope:)])
		self.database = [self.container databaseWithDatabaseScope:self.databaseScope];
	else {
		switch (self.databaseScope) {
			case CKDatabaseScopePublic:
				self.database = [self.container publicCloudDatabase];
				break;
			case CKDatabaseScopePrivate:
				self.database = [self.container privateCloudDatabase];
				break;
			default:
				NSAssert(NO, @"Unsupported database scope %ld", (long) self.databaseScope);
				break;
		}
	}
	
	[self.operationQueue addOperationWithBlock:^(CDOperation *operation) {
		[self.container accountStatusWithCompletionHandler:^(CKAccountStatus accountStatus, NSError * _Nullable error) {
			NSLog(@"AccountStatus %ld, error: %@", (long)accountStatus, error);
			if (!error) {
				self.accountStatus = accountStatus;
				[self loadRecordZone];
			}
			
			[operation finishWithError:error];
		}];
	}];
}

- (void) loadRecordZone {
	[self.operationQueue addOperationWithBlock:^(CDOperation *operation) {
		
		CKFetchRecordZonesOperation* databaseOperation = [[CKFetchRecordZonesOperation alloc] initWithRecordZoneIDs:@[self.recordZoneID]];
		databaseOperation.fetchRecordZonesCompletionBlock = ^(NSDictionary<CKRecordZoneID *, CKRecordZone *> * _Nullable recordZonesByZoneID, NSError * _Nullable operationError) {
			NSLog(@"CKFetchRecordZonesOperation error: %@", operationError);
			
			CKRecordZone* zone = recordZonesByZoneID[self.recordZoneID];
			if (!zone) {
				if ([operationError.domain isEqualToString:CKErrorDomain]) {
					NSError* zoneError = operationError.userInfo[CKPartialErrorsByItemIDKey][self.recordZoneID];
					if (zoneError.code == CKErrorZoneNotFound) {
						if (self.accountStatus == CKAccountStatusAvailable) {
							CKRecordZone* zone = [[CKRecordZone alloc] initWithZoneID:self.recordZoneID];
							[self.operationQueue addOperationWithBlock:^(CDOperation *operation) {
								CKModifyRecordZonesOperation* databaseOperation = [[CKModifyRecordZonesOperation alloc] initWithRecordZonesToSave:@[zone] recordZoneIDsToDelete:nil];
								databaseOperation.modifyRecordZonesCompletionBlock = ^(NSArray<CKRecordZone *> * _Nullable savedRecordZones, NSArray<CKRecordZoneID *> * _Nullable deletedRecordZoneIDs, NSError * _Nullable operationError) {
									NSLog(@"CKModifyRecordZonesOperation error: %@", operationError);
									if (!operationError && savedRecordZones.count > 0) {
										self.recordZone = [savedRecordZones lastObject];
										[self loadSubscription];
										[self pull];
										[self push];
									}
									[operation finishWithError:operationError];
									
								};
								[self.database addOperation:databaseOperation];
							}];
						}
						else {
							[operation finishWithError:operationError];
						}
					}
				}
			}
			else {
				self.recordZone = zone;
				[self loadSubscription];
				[self pull];
				[self push];
			}
			[operation finishWithError:operationError];
		};
		
		[self.database addOperation:databaseOperation];
	}];
}

- (void) loadSubscription {
	[self.operationQueue addOperationWithBlock:^(CDOperation *operation) {
		[self.database fetchSubscriptionWithID:CDSubscriptionID completionHandler:^(CKSubscription * _Nullable subscription, NSError * _Nullable error) {
			NSLog(@"fetchSubscriptionWithID error: %@", error);
			if (error && [error.domain isEqualToString:CKErrorDomain] && error.code == CKErrorUnknownItem) {
				CKSubscription* subscription = [[CKSubscription alloc] initWithZoneID:self.recordZoneID subscriptionID:CDSubscriptionID options:0];
				CKNotificationInfo* info = [CKNotificationInfo new];
				info.shouldSendContentAvailable = YES;
				subscription.notificationInfo = info;
				
				CKModifySubscriptionsOperation* databaseOperation = [[CKModifySubscriptionsOperation alloc] initWithSubscriptionsToSave:@[subscription] subscriptionIDsToDelete:nil];
				databaseOperation.modifySubscriptionsCompletionBlock = ^(NSArray<CKSubscription *> * _Nullable savedSubscriptions, NSArray<NSString *> * _Nullable deletedSubscriptionIDs, NSError * _Nullable operationError) {
					NSLog(@"CKModifySubscriptionsOperation error: %@", operationError);
					[operation finishWithError:operationError];
				};
				[self.database addOperation:databaseOperation];
			}
			else {
				[operation finishWithError:error];
			}
		}];
	}];
}

- (BOOL) iCloudIsAvailableForReading {
	if (self.databaseScope == CKDatabaseScopePublic)
		return self.database != nil && self.recordZone != nil;
	else
		return self.accountStatus == CKAccountStatusAvailable && self.database != nil && self.recordZone != nil;
}

- (BOOL) iCloudIsAvailableForWriting {
	return self.accountStatus == CKAccountStatusAvailable && self.database != nil && self.recordZone != nil;
}

#pragma mark - Save/Fetch requests

- (NSMergeConflict*) findConflictsInObject:(NSManagedObject*) object withRecord:(CDRecord*) record {
	NSArray* transactions = [[record.transactions allObjects] sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"version" ascending:YES]]];
	if (transactions.count > 0) {
		NSManagedObject* backingObject = [record valueForKey:record.recordType];
		if (backingObject) {
			NSIncrementalStoreNode* node = [self newValuesForObjectWithID:object.objectID withContext:object.managedObjectContext error:nil];
			NSMutableDictionary* cachedSnapshot = [NSMutableDictionary new];
			NSMutableDictionary* persistedSnapshot = [NSMutableDictionary new];
			
			for (NSPropertyDescription* property in object.objectID.entity.properties) {
				if ([property isKindOfClass:[NSRelationshipDescription class]] && [(NSRelationshipDescription*) property isToMany])
					continue;
				
				id value = [node valueForPropertyDescription:property];
				if (value)
					persistedSnapshot[property.name] = value;
				value = [object valueForKey:property.name];
				if (value)
					cachedSnapshot[property.name] = value;
			}
			return [[NSMergeConflict alloc] initWithSource:object newVersion:record.version + 1 oldVersion:record.version cachedSnapshot:persistedSnapshot persistedSnapshot:nil];
		}
		else
			return [[NSMergeConflict alloc] initWithSource:object newVersion:record.version + 1 oldVersion:0 cachedSnapshot:nil persistedSnapshot:nil];
	}
	else
		return nil;
}


- (id)executeSaveRequest:(NSSaveChangesRequest *)request withContext:(nullable NSManagedObjectContext*)context error:(NSError **)error {
	NSMutableDictionary* changedValues = [NSMutableDictionary new];
	NSMutableSet* objects = [NSMutableSet new];
	[objects unionSet:request.insertedObjects];
	[objects unionSet:request.updatedObjects];
	
	[_backingManagedObjectContext performBlockAndWait:^{
		NSMutableArray* conflicts = [NSMutableArray new];
		for (NSManagedObject* object in [objects setByAddingObjectsFromSet:request.deletedObjects]) {
			CDRecord* record = [self.backingObjectsHelper recordWithObjectID:object.objectID];
			NSMergeConflict* conflict = [self findConflictsInObject:object withRecord:record];
			if (conflict)
				[conflicts addObject:conflict];
		}
		
		NSError* errorr = nil;
		if (conflicts.count > 0) {
			[self.mergePolicy resolveConflicts:conflicts error:&errorr];
		}
		
		
		for (NSManagedObject* object in objects) {
			NSDictionary* relationships = object.entity.relationshipsByName;
			NSMutableDictionary* dic = [NSMutableDictionary new];
			[object.changedValues enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
				if (relationships[key]) {
					obj = [[object valueForKey:key] valueForKey:@"objectID"] ?: [NSNull null];
				}
				else {
					obj = [object valueForKey:key] ?: [NSNull null];
				}
				dic[key] = obj;
			}];
			changedValues[object.objectID] = dic;
		}
		
		CDTransaction* (^newChangeTransaction)(CDRecord*, NSString*, id) = ^(CDRecord* record, NSString* key, id value) {
			CDTransaction* transaction = [NSEntityDescription insertNewObjectForEntityForName:@"CDTransaction" inManagedObjectContext:_backingManagedObjectContext];
			transaction.record = record;
			transaction.version = record.version;
			transaction.action = CDTransactionActionChange;
			transaction.key = key;
			transaction.value = value;
			return transaction;
		};
		
		for (NSManagedObject* object in objects) {
			NSEntityDescription* entity = object.entity;
			NSDictionary* properties = entity.propertiesByName;
			
			
			CDRecord* record = [self.backingObjectsHelper recordWithObjectID:object.objectID];
			NSManagedObject* backingObject = [record valueForKey:record.recordType];
			if (!backingObject) {
				backingObject = [NSEntityDescription insertNewObjectForEntityForName:object.entity.name inManagedObjectContext:_backingManagedObjectContext];
				[backingObject setValue:record forKey:@"CDRecord"];
				[record setValue:backingObject forKey:record.recordType];
			}
			record.version++;
			
			CKRecord* ckRecord = objc_getAssociatedObject(object, @"CKRecord");
			
			[changedValues[object.objectID] enumerateKeysAndObjectsUsingBlock:^(NSString*  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
				NSPropertyDescription* property = properties[key];
				if ([obj isKindOfClass:[NSNull class]])
					obj = nil;
				
				if ([property isKindOfClass:[NSAttributeDescription class]]) {
					NSAttributeDescription* attribute = (NSAttributeDescription*) property;
					obj = [attribute transformedValue:obj];
					if (ckRecord) {
					}
					else
						newChangeTransaction(record, key, obj);
				}
				else if ([property isKindOfClass:[NSRelationshipDescription class]]) {
					NSRelationshipDescription* relationship = (NSRelationshipDescription*) property;
					if (relationship.toMany) {
						NSMutableSet* set = [NSMutableSet new];
						for (NSManagedObjectID* objectID in obj) {
							NSManagedObject* backingObject = [self.backingObjectsHelper backingObjectWithObjectID:objectID];
							if (backingObject)
								[set addObject:backingObject];
						}
						obj = set;
					}
					else if (obj)
						obj = [self.backingObjectsHelper backingObjectWithObjectID:obj];
					
					if ([relationship shouldSerialize]) {
						if (ckRecord) {
							
						}
						else {
							id value;
							if ([obj isKindOfClass:[NSSet class]]) {
								NSMutableSet* references = [NSMutableSet new];
								for (NSManagedObject* object in obj) {
									CDRecord* record = [object valueForKey:@"CDRecord"];
									[references addObject:record.recordID];
								}
								value = references;
							}
							else {
								if (obj) {
									CDRecord* record = [obj valueForKey:@"CDRecord"];
									value = record.recordID;
								}
								else
									value = nil;
							}
							newChangeTransaction(record, key, value);
						}
					}
				}
				[backingObject setValue:obj forKey:key];
			}];
		}
		
		for (NSManagedObject* object in request.deletedObjects) {
			NSManagedObject* backingObject = [self.backingObjectsHelper backingObjectWithObjectID:object.objectID];
			if (backingObject) {
				CDRecord* record = [backingObject valueForKey:@"CDRecord"];
				BOOL logTransactions = !objc_getAssociatedObject(object, @"CKRecord");
				if (logTransactions) {
					CDTransaction* transaction = [NSEntityDescription insertNewObjectForEntityForName:@"CDTransaction" inManagedObjectContext:_backingManagedObjectContext];
					transaction.record = record;
					transaction.action = CDTransactionActionDelete;
				}
				[_backingManagedObjectContext deleteObject:backingObject];
			}
		}
		if ([_backingManagedObjectContext hasChanges])
			[_backingManagedObjectContext save:error];
	[self push];
	}];
	return @[];
}

- (id)executeFetchRequest:(NSFetchRequest *)request withContext:(nullable NSManagedObjectContext*)context error:(NSError **)error {
	NSMutableArray* objects = [NSMutableArray new];
	NSFetchRequestResultType resultType = request.resultType;
	[_backingManagedObjectContext performBlockAndWait:^{
		NSFetchRequest* backingRequest = [request copy];
		backingRequest.entity = _backingManagedObjectModel.entitiesByName[request.entityName ?: request.entity.name];
		
		if (backingRequest.resultType == NSManagedObjectIDResultType)
			backingRequest.resultType = NSManagedObjectResultType;
		
		NSArray* fetchResult = [_backingManagedObjectContext executeFetchRequest:backingRequest error:error];
		switch (resultType) {
			case NSManagedObjectResultType:
			case NSManagedObjectIDResultType:
				for (NSManagedObject* object in fetchResult) {
					CDRecord* record = [object valueForKey:@"CDRecord"];
					[objects addObject:[self newObjectIDForEntity:request.entity referenceObject:record.recordID]];
				}
				break;
			case NSDictionaryResultType:
			case NSCountResultType:
				for (id object in fetchResult)
					[objects addObject:object];
				break;
			default:
				break;
		}
	}];
	
	
	NSMutableArray* result = [NSMutableArray new];
	
	switch (resultType) {
		case NSManagedObjectResultType:
			for (NSManagedObjectID* objectID in objects)
				[result addObject:[context objectWithID:objectID]];
			break;
		case NSManagedObjectIDResultType:
			for (NSManagedObjectID* objectID in objects)
				[result addObject:objectID];
			break;
		case NSDictionaryResultType:
		case NSCountResultType:
			result = objects;
			break;
		default:
			break;
	}
	
	return result;
}

#pragma mark - Notification handlers

- (void) managedObjectContextDidSave:(NSNotification*) notification {
	NSManagedObjectContext* other = notification.object;
	if (other != _backingManagedObjectContext && other.persistentStoreCoordinator == _backingPersistentStoreCoordinator)
		[_backingManagedObjectContext performBlock:^{
			[_backingManagedObjectContext mergeChangesFromContextDidSaveNotification:notification];
		}];
}

- (void) ubiquityIdentityDidChange:(NSNotification*) notification {
	id token = [[NSFileManager defaultManager] ubiquityIdentityToken];
	if (![token isEqual:self.ubiquityIdentityToken]) {
		if (_backingPersistentStore) {
			[_backingPersistentStoreCoordinator removePersistentStore:_backingPersistentStore error:nil];
			[self loadBackingStoreWithError:nil];
		}
	}
}

- (void) didReceiveRemoteNotification:(NSNotification*) notification {
//	CKRecordZoneNotification* note;
//	if (notification.userInfo)
//		note = [CKRecordZoneNotification notificationFromRemoteNotificationDictionary:notification.userInfo];
//	
//	
//	if ([note.containerIdentifier isEqualToString:[self.container containerIdentifier]] && [note.recordZoneID isEqual:self.zoneID]) {
//		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pull) object:nil];
//		[self performSelector:@selector(pull) withObject:nil afterDelay:1];
//	}
}

#pragma mark - Pull/Push

- (void) push {
	if ([self iCloudIsAvailableForWriting]) {
		@synchronized (self) {
			if (self.pushing)
				return;
			self.pushing = YES;
		}
		CDPushOperation* operation = [[CDPushOperation alloc] initWithStore:self completionHandler:^(NSError *error, NSArray<CKRecord *> *conflicts) {
			@synchronized (self) {
				self.pushing = NO;
			}
		}];
		[self.operationQueue addOperation:operation];
	}
}

- (void) pull {
	if ([self iCloudIsAvailableForReading]) {
		@synchronized (self) {
			if (self.pulling)
				return;
			self.pulling = YES;
		}
		CDPullOperation* operation = [[CDPullOperation alloc] initWithStore:self completionHandler:^(BOOL moreComing, NSError *error) {
			@synchronized (self) {
				self.pushing = NO;
			}
			if (moreComing)
				[self pull];
		}];
		[self.operationQueue addOperation:operation];
	}
}

@end
