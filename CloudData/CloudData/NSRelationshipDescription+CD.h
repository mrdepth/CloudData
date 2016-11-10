//
//  NSRelationshipDescription+CD.h
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import <CoreData/CoreData.h>

@class CKReference, CKRecordZoneID;
@interface NSRelationshipDescription (CD)

- (BOOL) shouldSerialize;
- (id) CKReferenceFromBackingObject:(NSManagedObject*) object recordZoneID:(CKRecordZoneID*) recordZoneID;

@end
