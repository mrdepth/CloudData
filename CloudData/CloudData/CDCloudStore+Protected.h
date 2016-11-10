//
//  CDCloudStore+Protected.h
//  CloudData
//
//  Created by Artem Shimanski on 10.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#ifndef CDCloudStore_Protected_h
#define CDCloudStore_Protected_h
#import <CloudKit/CloudKit.h>
#import <CoreData/CoreData.h>
#import "CDOperationQueue.h"
#import "CDBackingObjectHelper.h"
#import "CDRecord+CoreDataClass.h"
#import "CDTransaction+CoreDataClass.h"
#import "NSAttributeDescription+CD.h"
#import "NSRelationshipDescription+CD.h"

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
@property (nonatomic, strong) id ubiquityIdentityToken;
@property (nonatomic, strong) CDBackingObjectHelper* backingObjectsHelper;

@property (nonatomic, strong) CKRecordZoneID* recordZoneID;
@property (nonatomic, strong) CKRecordZone* recordZone;
@property (nonatomic, strong) CKDatabase* database;
@property (nonatomic, strong) CKContainer* container;
@property (nonatomic, assign) CKDatabaseScope databaseScope;
@property (nonatomic, assign) CKAccountStatus accountStatus;
@property (nonatomic, strong) NSMergePolicy* mergePolicy;

@end

#endif /* CDCloudStore_Protected_h */
