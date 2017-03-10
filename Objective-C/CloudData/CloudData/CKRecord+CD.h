//
//  CKRecord+CD.h
//  CloudData
//
//  Created by Artem Shimanski on 10.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import <CloudKit/CloudKit.h>

@class NSManagedObject, CDCloudStore, NSEntityDescription;
@interface CKRecord (CD)

- (NSDictionary<NSString*, id>*) changedValuesWithObject:(NSManagedObject*) backingObject entity:(NSEntityDescription*) entity;
- (NSDictionary<NSString*, id>*) nodeValuesInStore:(CDCloudStore*) store includeToManyRelationships:(BOOL) useToMany;
@end
