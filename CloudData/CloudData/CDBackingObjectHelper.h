//
//  CDBackingObjectHelper.h
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class CDCloudStore, CDRecord;
@interface CDBackingObjectHelper : NSObject

- (id) initWithStore:(CDCloudStore*) store managedObjectContext:(NSManagedObjectContext*) managedObjectContext;

- (NSManagedObject*) backingObjectWithObjectID:(NSManagedObjectID*) objectID;
- (CDRecord*) recordWithObjectID:(NSManagedObjectID*) objectID;
- (NSManagedObjectID*) objectIDWithBackingObject:(NSManagedObject*) object;


@end
