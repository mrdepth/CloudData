//
//  CDOperationQueue.h
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "CDOperation.h"

@interface CDOperationQueue : NSObject
@property (nonatomic, assign) BOOL allowsWWAN;

- (void) addOperation:(CDOperation*) operation;
- (void) addOperationWithBlock:(void(^)(CDOperation* operation)) block;

@end
