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




@interface CDCloudStore : NSIncrementalStore

@end
