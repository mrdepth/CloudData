//
//  NSRelationshipDescription+CD.h
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import <CoreData/CoreData.h>

@class CKReference, CKRecordZoneID, CKRecord, CDCloudStore;
@interface NSRelationshipDescription (CD)

- (BOOL) shouldSerialize;
- (id) CKReferenceFromBackingObject:(NSManagedObject*) object recordZoneID:(CKRecordZoneID*) recordZoneID;
- (id) managedReferenceFromCKRecord:(CKRecord*) record inStore:(CDCloudStore*) store;
- (NSManagedObjectID*) managedReferenceFromCKReference:(CKReference*) reference inStore:(CDCloudStore*) store;

@end
