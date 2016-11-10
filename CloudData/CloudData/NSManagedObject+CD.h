//
//  NSManagedObject+CD.h
//  CloudData
//
//  Created by Artem Shimanski on 10.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import <CoreData/CoreData.h>

@class CKRecord;
@interface NSManagedObject (CD)

- (NSDictionary<NSString*, id>*) changedValuesWithRecord:(CKRecord*) record;
@end
