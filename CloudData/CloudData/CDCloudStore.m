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
#import <UIKit/UIKit.h>
#import "CDCloudStore+Protected.h"
#import "CDPushOperation.h"
#import "CDPullOperation.h"
#import "CDMetadata+CoreDataClass.h"
#import "CDManagedObjectContext.h"
#import "CKRecord+CD.h"


NSString * const CDCloudStoreType = @"CDCloudStore";

NSString * const CDCloudStoreOptionContainerIdentifierKey = @"CDCloudStoreOptionContainerIdentifierKey";
NSString * const CDCloudStoreOptionDatabaseScopeKey = @"CDCloudStoreOptionDatabaseScopeKey";
NSString * const CDCloudStoreOptionRecordZoneKey = @"CDCloudStoreOptionRecordZoneKey";
NSString * const CDCloudStoreOptionMergePolicyType = @"CDCloudStoreOptionMergePolicyType";

NSString * const CDDidReceiveRemoteNotification = @"CDDidReceiveRemoteNotification";
NSString * const CDCloudStoreDidInitializeCloudAccountNotification = @"CDCloudStoreDidInitializeCloudAccountNotification";
NSString * const CDCloudStoreDidFailtToInitializeCloudAccountNotification = @"CDCloudStoreDidFailtToInitializeCloudAccountNotification";
NSString * const CDCloudStoreDidStartCloudImportNotification = @"CDCloudStoreDidStartCloudImportNotification";
NSString * const CDCloudStoreDidFinishCloudImportNotification = @"CDCloudStoreDidFinishCloudImportNotification";
NSString * const CDCloudStoreDidFailCloudImportNotification = @"CDCloudStoreDidFailCloudImportNotification";

NSString * const CDErrorKey;


NSString * const CDSubscriptionID = @"autoUpdate";

@interface CDManagedObjectContext()
@property (nonatomic, assign) BOOL loadFromCache;
@end

@interface MyNode : NSIncrementalStoreNode

@end

@implementation MyNode

- (void) updateWithValues:(NSDictionary<NSString *,id> *)values version:(uint64_t)version {
	[super updateWithValues:values version:version];
}

@end


@interface CDCloudStore()
@property (nonatomic, assign, getter = isPushing) BOOL pushing;
@property (nonatomic, assign, getter = isPulling) BOOL pulling;
@property (nonatomic, strong) NSTimer* autoPushTimer;
@property (nonatomic, strong) NSTimer* autoPullTimer;
@property (nonatomic, assign) BOOL needsInitialImport;

@end

@implementation CDCloudStore

+ (void) handleRemoteNotification:(NSDictionary*) userInfo {
	[[NSNotificationCenter defaultCenter] postNotificationName:CDDidReceiveRemoteNotification object:nil userInfo:userInfo];
}

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
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
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
			cdRecord.cache = [NSEntityDescription insertNewObjectForEntityForName:@"CDRecordCache" inManagedObjectContext:_backingManagedObjectContext];
			cdRecord.cache.cachedRecord = record ?: [[CKRecord alloc] initWithRecordType:cdRecord.recordType zoneID:self.recordZoneID];
			cdRecord.recordID = cdRecord.cache.cachedRecord.recordID.recordName;
			[result addObject:[self newObjectIDForEntity:object.entity referenceObject:cdRecord.recordID]];
		}
	}];
	
	return result;
}

- (nullable NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID*)objectID withContext:(NSManagedObjectContext*)context error:(NSError**)error {
	__block NSDictionary* values = nil;
	
	__block int64_t version = 0;
	[_backingManagedObjectContext performBlockAndWait:^{
		if ([context isKindOfClass:[CDManagedObjectContext class]] && [(CDManagedObjectContext*) context loadFromCache]) {
			CDRecord* record = [self.backingObjectsHelper recordWithObjectID:objectID];
			if (record) {
				values = [record.cache.cachedRecord nodeValuesInStore:self includeToManyRelationships:NO];
				version = record.cache.version;
			}
		}
		else {
			NSManagedObject* backingObject = [self.backingObjectsHelper backingObjectWithObjectID:objectID];
			if (!backingObject)
				return;
			NSMutableDictionary* dic = [NSMutableDictionary new];
			NSEntityDescription* entity = _entities[backingObject.entity.name];
			for (NSString* key in entity.attributesByName.allKeys) {
				id obj = [backingObject valueForKey:key];
				if (obj)
					dic[key] = obj;
			}
			[entity.relationshipsByName enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, NSRelationshipDescription * _Nonnull obj, BOOL * _Nonnull stop) {
				if (!obj.toMany) {
					NSManagedObject* reference = [backingObject valueForKey:key];
					if (reference)
						dic[key] = [self.backingObjectsHelper objectIDWithBackingObject:reference];
					else
						dic[key] = [NSNull null];
				}
			}];
			
			CDRecord* record = [backingObject valueForKey:@"CDRecord"];
			version = record.version;
			values = dic;
		}
	}];
	return values ? [[MyNode alloc] initWithObjectID:objectID withValues:values version:version] : nil;
}

- (nullable id)newValueForRelationship:(NSRelationshipDescription*)relationship forObjectWithID:(NSManagedObjectID*)objectID withContext:(nullable NSManagedObjectContext *)context error:(NSError **)error {
	__block id result = nil;
	[_backingManagedObjectContext performBlockAndWait:^{
		if ([context isKindOfClass:[CDManagedObjectContext class]] && [(CDManagedObjectContext*) context loadFromCache]) {
			CDRecord* record = [self.backingObjectsHelper recordWithObjectID:objectID];
			if (record) {
				result = [relationship managedReferenceFromCKRecord:record inStore:self];
			}
		}
		else {
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
		}
	}];
	return result;
}

- (NSManagedObjectID *)newObjectIDForEntity:(NSEntityDescription *)entity referenceObject:(id)data {
	return [super newObjectIDForEntity:entity referenceObject:[@"id" stringByAppendingString:data]];
}

- (id)referenceObjectForObjectID:(NSManagedObjectID *)objectID {
	return [[super referenceObjectForObjectID:objectID] substringFromIndex:2];
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
		inverseRelationship.inverseRelationship = relationship;
		relationship.destinationEntity.properties = [relationship.destinationEntity.properties arrayByAddingObject:inverseRelationship];
	}
	recordEntity.properties = properties;
	
	return backingModel;
}

- (BOOL) loadBackingStoreWithError:(NSError **)error {
	self.autoPushTimer = nil;
	self.autoPullTimer = nil;
	self.accountStatus = CKAccountStatusCouldNotDetermine;

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
	
	if (self.backingPersistentStore && (self.databaseScope == CKDatabaseScopePublic || token)) {
		NSManagedObjectContext* context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
		context.persistentStoreCoordinator = _backingPersistentStoreCoordinator;
		[context performBlockAndWait:^{
			CDMetadata* metadata = [[context executeFetchRequest:[CDMetadata fetchRequest] error:nil] lastObject];
			if (!metadata) {
				metadata = [NSEntityDescription insertNewObjectForEntityForName:@"CDMetadata" inManagedObjectContext:context];
				metadata.recordZoneID = self.recordZoneID;
				metadata.uuid = [NSUUID UUID].UUIDString;
				[context save:nil];
			}
			self.needsInitialImport = metadata.serverChangeToken == nil;
			NSMutableDictionary* dic = [self.metadata mutableCopy];
			dic[NSStoreUUIDKey] = metadata.uuid;
			self.metadata = dic;
		}];
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
			else
				[[NSNotificationCenter defaultCenter] postNotificationName:CDCloudStoreDidFailtToInitializeCloudAccountNotification object:self userInfo:@{CDErrorKey:error}];
			
			[operation finishWithError:error];
		}];
	}];
}

- (void) loadRecordZone {
	void (^next)() = ^{
		[[NSNotificationCenter defaultCenter] postNotificationName:CDCloudStoreDidInitializeCloudAccountNotification object:self userInfo:nil];
		[self pull];
		[self loadSubscription];
		
		if ([self iCloudIsAvailableForWriting]) {
			self.autoPushTimer = [NSTimer timerWithTimeInterval:10 target:self selector:@selector(push) userInfo:nil repeats:YES];
		}
	};
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
										next();
									}
									else
										[[NSNotificationCenter defaultCenter] postNotificationName:CDCloudStoreDidFailtToInitializeCloudAccountNotification object:self userInfo:operationError ? @{CDErrorKey:operationError} : nil];

									[operation finishWithError:operationError];
									
								};
								[self.database addOperation:databaseOperation];
							}];
							
							return;
						}
					}
				}
				[[NSNotificationCenter defaultCenter] postNotificationName:CDCloudStoreDidFailtToInitializeCloudAccountNotification object:self userInfo:operationError ? @{CDErrorKey:operationError} : nil];
			}
			else {
				self.recordZone = zone;
				next();
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

- (id)executeSaveRequest:(NSSaveChangesRequest *)request withContext:(nullable NSManagedObjectContext*)context error:(NSError **)error {
	NSMutableDictionary* changedValues = [NSMutableDictionary new];
	NSMutableSet* objects = [NSMutableSet new];
	[objects unionSet:request.insertedObjects];
	[objects unionSet:request.updatedObjects];

	[_backingManagedObjectContext performBlockAndWait:^{
		
		NSManagedObject* (^getBackingObject)(NSManagedObject*) = ^(NSManagedObject* object) {
			CDRecord* record = [self.backingObjectsHelper recordWithObjectID:object.objectID];
			return [record valueForKey:record.recordType];
		};
		
		for (NSManagedObject* object in request.insertedObjects) {
			CDRecord* record = [self.backingObjectsHelper recordWithObjectID:object.objectID];
			NSManagedObject* backingObject = [NSEntityDescription insertNewObjectForEntityForName:object.entity.name inManagedObjectContext:_backingManagedObjectContext];
			[backingObject setValue:record forKey:@"CDRecord"];
			[record setValue:backingObject forKey:record.recordType];
		}
		
		for (NSManagedObject* object in objects) {
			CDRecord* record = [self.backingObjectsHelper recordWithObjectID:object.objectID];
			NSManagedObject* backingObject = [record valueForKey:record.recordType];
			if (!backingObject) {
				backingObject = [NSEntityDescription insertNewObjectForEntityForName:object.entity.name inManagedObjectContext:_backingManagedObjectContext];
				[backingObject setValue:record forKey:@"CDRecord"];
				[record setValue:backingObject forKey:record.recordType];
			}
			
			NSDictionary* propertiesByName = object.entity.propertiesByName;
			[object.changedValues enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
				NSPropertyDescription* property = propertiesByName[key];
				if ([property isKindOfClass:[NSAttributeDescription class]])
					[backingObject setValue:obj forKey:key];
				else if ([property isKindOfClass:[NSRelationshipDescription class]]) {
					NSRelationshipDescription* relationship = (NSRelationshipDescription*) property;
					if (relationship.toMany) {
						NSMutableSet* set = [NSMutableSet new];
						for (NSManagedObject* object in obj) {
							NSManagedObject* reference = getBackingObject(object);
							[set addObject:reference];
						}
						[backingObject setValue:set forKey:key];
					}
					else if ([obj isKindOfClass:[NSManagedObject class]])
						[backingObject setValue:getBackingObject(obj) forKey:key];
					else
						[backingObject setValue:nil forKey:key];
				}
			}];
			CKRecord* ckRecord = objc_getAssociatedObject(object, @"CKRecord");
			if (ckRecord) {
				record.cache.cachedRecord = ckRecord;
				if (record.version == record.cache.version)
					record.cache.version++;
			}
			record.version++;
		}
		
		for (NSManagedObject* object in request.deletedObjects) {
			CDRecord* record = [self.backingObjectsHelper recordWithObjectID:object.objectID];
			NSManagedObject* backingObject = [record valueForKey:record.recordType];
			if (backingObject)
				[_backingManagedObjectContext deleteObject:backingObject];
			
			CKRecordID* ckRecordID = objc_getAssociatedObject(object, @"CKRecordID");
			if (ckRecordID)
				[_backingManagedObjectContext deleteObject:record];
			record.version = 0;
		}
		
		if ([_backingManagedObjectContext hasChanges])
			[_backingManagedObjectContext save:error];
	}];
	dispatch_async(dispatch_get_main_queue(), ^{
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(push) object:nil];
		[self performSelector:@selector(push) withObject:nil afterDelay:1];
	});
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
	CKRecordZoneNotification* note;
	if (notification.userInfo)
		note = [CKRecordZoneNotification notificationFromRemoteNotificationDictionary:notification.userInfo];
	
	
	if ([note.containerIdentifier isEqualToString:[self.container containerIdentifier]] && [note.recordZoneID isEqual:self.recordZoneID]) {
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pull) object:nil];
		[self performSelector:@selector(pull) withObject:nil afterDelay:1];
	}
}

- (void) didBecomeActive:(NSNotification*) notification {
	[self.operationQueue resume];
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pull) object:nil];
	[self performSelector:@selector(pull) withObject:nil afterDelay:3];
	if (self.autoPushTimer)
		[[NSRunLoop mainRunLoop] addTimer:self.autoPushTimer forMode:NSDefaultRunLoopMode];
	if (self.autoPullTimer)
		[[NSRunLoop mainRunLoop] addTimer:self.autoPullTimer forMode:NSDefaultRunLoopMode];
}

- (void) willResignActive:(NSNotification*) notification {
	[self.operationQueue suspend];
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pull) object:nil];
	[self.autoPushTimer invalidate];
	[self.autoPullTimer invalidate];
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
			if (conflicts.count > 0)
				[self pull];

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
		if (self.needsInitialImport)
			[[NSNotificationCenter defaultCenter] postNotificationName:CDCloudStoreDidStartCloudImportNotification object:self];
		__block CDPullOperation* operation = [[CDPullOperation alloc] initWithStore:self completionHandler:^(BOOL moreComing, NSError *error) {
			if (moreComing)
				[self.operationQueue addOperation:operation];
			else {
				if (self.needsInitialImport) {
					if (error)
						[[NSNotificationCenter defaultCenter] postNotificationName:CDCloudStoreDidFailCloudImportNotification object:self userInfo:@{CDErrorKey:error}];
					else {
						[[NSNotificationCenter defaultCenter] postNotificationName:CDCloudStoreDidFinishCloudImportNotification object:self];
						self.needsInitialImport = NO;
					}
				}
				@synchronized (self) {
					self.pulling = NO;
				}
				[self push];
			}
		}];
		[self.operationQueue addOperation:operation];
	}
}

#pragma mark - Timers

- (void) setAutoPushTimer:(NSTimer *)autoPushTimer {
	[_autoPushTimer invalidate];
	_autoPushTimer = autoPushTimer;
	if (_autoPushTimer)
		[[NSRunLoop mainRunLoop] addTimer:_autoPushTimer forMode:NSDefaultRunLoopMode];
}

- (void) setAutoPullTimer:(NSTimer *)autoPullTimer {
	[_autoPullTimer invalidate];
	_autoPullTimer = autoPullTimer;
	if (_autoPullTimer)
		[[NSRunLoop mainRunLoop] addTimer:_autoPullTimer forMode:NSDefaultRunLoopMode];
}

@end
