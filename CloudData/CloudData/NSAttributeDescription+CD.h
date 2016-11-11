//
//  NSAttributeDescription+CD.h
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import <CoreData/CoreData.h>

@protocol CKRecordValue;
@class CKRecord;
@interface NSAttributeDescription (CD)

- (id) reverseTransformValue:(id) value;
- (id) transformedValue:(id)value;
- (id<CKRecordValue>) CKRecordValueFromBackingObject:(NSManagedObject*) object;
- (id) managedValueFromCKRecord:(CKRecord*) record;

@end
