//
//  CDCloudStore.m
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import <CloudKit/CloudKit.h>
#import <CoreData/CoreData.h>
#import "CDCloudStore.h"
#import "CDOperationQueue.h"
#import "NSUUID+CD.h"
#import "NSAttributeDescription+CD.h"
#import "NSRelationshipDescription+CD.h"
#import <objc/runtime.h>
#import "CDBackingObjectHelper.h"
#import "CDRecord+CoreDataClass.h"
#import "CDTransaction+CoreDataClass.h"


NSString * const CDCloudStoreType = @"CDCloudStore";

NSString * const CDCloudStoreOptionContainerIdentifierKey = @"CDCloudStoreOptionContainerIdentifierKey";
NSString * const CDCloudStoreOptionDatabaseScopeKey = @"CDCloudStoreOptionDatabaseScopeKey";
NSString * const CDCloudStoreOptionRecordZoneKey = @"CDCloudStoreOptionRecordZoneKey";

NSString * const CDDidReceiveRemoteNotification = @"CDDidReceiveRemoteNotification";

typedef NS_ENUM(NSInteger, CDTransactionAction) {
	CDTransactionActionChange,
	CDTransactionActionDelete
};

@interface CDCloudStore()
@property (nonatomic, strong) CDOperationQueue* operationQueue;
@property (nonatomic, strong) NSPersistentStoreCoordinator* backingPersistentStoreCoordinator;
@property (nonatomic, strong) NSPersistentStore* backingPersistentStore;
@property (nonatomic, strong) NSManagedObjectModel* backingManagedObjectModel;
@property (nonatomic, strong) NSManagedObjectContext* backingManagedObjectContext;
@property (nonatomic, strong) NSDictionary<NSString*, NSEntityDescription*>* entities;
@property (nonatomic, strong) CKRecordZoneID* recordZoneID;
@property (nonatomic, strong) id ubiquityIdentityToken;
@property (nonatomic, strong) CDBackingObjectHelper* backingObjectsHelper;

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
	NSMutableDictionary* values = [NSMutableDictionary new];
	
	__block int64_t version = 0;
	[_backingManagedObjectContext performBlockAndWait:^{
		NSManagedObject* backingObject = [self.backingObjectsHelper backingObjectWithObjectID:objectID];
		if (!backingObject)
			return;
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
	return [[NSIncrementalStoreNode alloc] initWithObjectID:objectID withValues:values version:version];
}

- (nullable id)newValueForRelationship:(NSRelationshipDescription*)relationship forObjectWithID:(NSManagedObjectID*)objectID withContext:(nullable NSManagedObjectContext *)context error:(NSError **)error {
	__block id result;
	[_backingManagedObjectContext performBlockAndWait:^{
		NSManagedObject* backingObject = [self.backingObjectsHelper backingObjectWithObjectID:objectID];
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
		
		relationship.inverseRelationship = relationship;
		relationship.destinationEntity.properties = [relationship.destinationEntity.properties arrayByAddingObject:inverseRelationship];
	}
	recordEntity.properties = properties;
	
	return backingModel;
}

- (BOOL) loadBackingStoreWithError:(NSError **)error {
	id value = self.options[CDCloudStoreOptionDatabaseScopeKey];
	id zone = self.options[CDCloudStoreOptionRecordZoneKey] ?: [[self.URL lastPathComponent] stringByDeletingPathExtension];
	
	NSString* owner = floor(NSFoundationVersionNumber) <= NSFoundationVersionNumber_iOS_9_x_Max ? CKOwnerDefaultName : CKCurrentUserDefaultName;
	self.recordZoneID = [[CKRecordZoneID alloc] initWithZoneName:zone ownerName:owner];
	
	NSString* containerIdentifier = self.options[CDCloudStoreOptionContainerIdentifierKey];
	CKDatabaseScope databaseScope = value ? [value integerValue] : CKDatabaseScopePrivate;
	
	id token = [[NSFileManager defaultManager] ubiquityIdentityToken];
	self.ubiquityIdentityToken = token;
	
	NSString* identifier;
	if (databaseScope == CKDatabaseScopePrivate && token)
		identifier = [NSUUID UUIDWithUbiquityIdentityToken:token].UUIDString;
	else
		identifier = @"local";
	NSURL* url = [self.URL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@.sqlite", identifier, self.recordZoneID.zoneName]];

	[[NSFileManager defaultManager] createDirectoryAtPath:[url.path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:error];
	
	self.backingPersistentStore = [_backingPersistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:url options:@{} error:error];
	
	/*self.accountStatus = CKAccountStatusCouldNotDetermine;
	if (_backingPersistentStore && (databaseScope == CKDatabaseScopePublic || token)) {
		self.container = containerIdentifier ? [CKContainer containerWithIdentifier:containerIdentifier] : [CKContainer defaultContainer];
		[self loadDatabaseWithScope:databaseScope];
		return YES;
	}
	else {
		self.database = nil;
		return NO;
	}*/
	
	return self.backingPersistentStore != nil;
}

#pragma mark - Save/Fetch requests

- (id)executeSaveRequest:(NSSaveChangesRequest *)request withContext:(nullable NSManagedObjectContext*)context error:(NSError **)error {
	NSMutableDictionary* changedValues = [NSMutableDictionary new];
	NSMutableSet* objects = [NSMutableSet new];
	[objects unionSet:request.insertedObjects];
	[objects unionSet:request.updatedObjects];
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
	
	
	[_backingManagedObjectContext performBlockAndWait:^{
		
		CDTransaction* (^newChangeTransaction)(CDRecord*, NSString*, id) = ^(CDRecord* record, NSString* key, id value) {
			CDTransaction* transaction = [NSEntityDescription insertNewObjectForEntityForName:@"CDTransaction" inManagedObjectContext:_backingManagedObjectContext];
			transaction.record = record;
			transaction.recordChangeTag = record.record.recordChangeTag;
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
			}
			record.version++;
			
			BOOL logTransactions = !objc_getAssociatedObject(object, @"CKRecord");
			
			
			[changedValues[object.objectID] enumerateKeysAndObjectsUsingBlock:^(NSString*  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
				NSPropertyDescription* property = properties[key];
				if ([obj isKindOfClass:[NSNull class]])
					obj = nil;
				
				if ([property isKindOfClass:[NSAttributeDescription class]]) {
					NSAttributeDescription* attribute = (NSAttributeDescription*) property;
					obj = [attribute transformedValue:obj];
					if (logTransactions)
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
					
					if ([relationship shouldSerialize] && logTransactions) {
						id value;
						if ([obj isKindOfClass:[NSSet class]]) {
							NSMutableSet* references = [NSMutableSet new];
							for (NSManagedObject* object in obj) {
								CDRecord* record = [self.backingObjectsHelper recordWithObjectID:object.objectID];
								[references addObject:record.recordID];
							}
							value = references;
						}
						else {
							if (obj) {
								CDRecord* record = [self.backingObjectsHelper recordWithObjectID:[obj objectID]];
								value = record.recordID;
							}
							else
								value = nil;
						}
						newChangeTransaction(record, key, value);
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
	//	[self push];
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

@end
