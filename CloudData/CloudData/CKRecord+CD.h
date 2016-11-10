//
//  CKRecord+CD.h
//  CloudData
//
//  Created by Artem Shimanski on 10.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import <CloudKit/CloudKit.h>

@class NSManagedObject;
@interface CKRecord (CD)

- (NSDictionary<NSString*, id>*) changedValuesWithObject:(NSManagedObject*) object;
@end
