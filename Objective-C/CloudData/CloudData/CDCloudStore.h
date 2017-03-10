//
//  CDCloudStore.h
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import <CoreData/CoreData.h>

FOUNDATION_EXPORT NSString * const CDCloudStoreType;

FOUNDATION_EXPORT NSString * const CDCloudStoreOptionContainerIdentifierKey;
FOUNDATION_EXPORT NSString * const CDCloudStoreOptionDatabaseScopeKey;
FOUNDATION_EXPORT NSString * const CDCloudStoreOptionRecordZoneKey;
FOUNDATION_EXPORT NSString * const CDCloudStoreOptionMergePolicyType;

FOUNDATION_EXPORT NSString * const CDDidReceiveRemoteNotification;
FOUNDATION_EXPORT NSString * const CDCloudStoreDidInitializeCloudAccountNotification;
FOUNDATION_EXPORT NSString * const CDCloudStoreDidFailtToInitializeCloudAccountNotification;
FOUNDATION_EXPORT NSString * const CDCloudStoreDidStartCloudImportNotification;
FOUNDATION_EXPORT NSString * const CDCloudStoreDidFinishCloudImportNotification;
FOUNDATION_EXPORT NSString * const CDCloudStoreDidFailCloudImportNotification;

FOUNDATION_EXPORT NSString * const CDErrorKey;



@interface CDCloudStore : NSIncrementalStore

+ (void) handleRemoteNotification:(NSDictionary*) userInfo;

@end
