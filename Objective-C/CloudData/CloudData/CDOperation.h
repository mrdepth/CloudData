//
//  CDOperation.h
//  CloudData
//
//  Created by Artem Shimanski on 10.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface CDOperation : NSOperation
@property (readonly) BOOL shouldRetry;
@property (nonatomic, strong, readonly) NSDate* fireDate;

- (void) finishWithError:(NSError*) error;
- (void) retryAfter:(NSTimeInterval) after;
@end

@interface CDBlockOperation : CDOperation

+ (instancetype) operationWithBlock:(void(^)(CDOperation* operation)) block;

@end
