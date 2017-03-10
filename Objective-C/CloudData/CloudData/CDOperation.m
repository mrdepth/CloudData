//
//  CDOperation.m
//  CloudData
//
//  Created by Artem Shimanski on 10.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "CDOperation.h"
@import CloudKit;

static NSInteger CDOperationRetryLimit = 3;

@interface CDOperation() {
	BOOL _executing;
	BOOL _finished;
	NSInteger _retryCounter;
}
@property (nonatomic, strong, readwrite) NSDate* fireDate;
@end

@implementation CDOperation

- (id) init {
	if (self = [super init]) {
		_retryCounter = 0;
	}
	return self;
}

- (BOOL) isAsynchronous {
	return YES;
}

- (BOOL) isFinished {
	return _finished;
}

- (BOOL) isExecuting {
	return _executing;
}

- (void) start {
	self.fireDate = nil;
	[self willChangeValueForKey:@"isExecuting"];
	_executing = YES;
	_finished = NO;
	[self didChangeValueForKey:@"isExecuting"];
	[self main];
}

- (void) main {
	[self finishWithError:nil];
}

- (void) finishWithError:(NSError*) error {
	if (error && [error.domain isEqualToString:CKErrorDomain]) {
		switch (error.code) {
			case CKErrorNetworkUnavailable:
			case CKErrorNetworkFailure:
			case CKErrorServiceUnavailable:
			case CKErrorRequestRateLimited:
			case CKErrorNotAuthenticated: {
				if (_retryCounter < CDOperationRetryLimit) {
					_retryCounter++;
					NSTimeInterval retryAfter = [error.userInfo[CKErrorRetryAfterKey] doubleValue];
					if (retryAfter == 0)
						retryAfter = 3;
					self.fireDate = [NSDate dateWithTimeIntervalSinceNow:retryAfter];
					NSLog(@"Error: %@. Retry after %f", error, retryAfter);
					break;
				}
			}
			default:
				break;
		}
	}
	
	[self willChangeValueForKey:@"isFinished"];
	[self willChangeValueForKey:@"isExecuting"];
	_finished = YES;
	_executing = NO;
	[self didChangeValueForKey:@"isExecuting"];
	[self didChangeValueForKey:@"isFinished"];
}

- (void) retryAfter:(NSTimeInterval) after {
	self.fireDate = [NSDate dateWithTimeIntervalSinceNow:after];
	[self finishWithError:nil];
}

- (BOOL) shouldRetry {
	return self.fireDate != nil;
}

@end

@implementation CDBlockOperation {
	void(^_block)(CDOperation* operation);
}

+ (instancetype) operationWithBlock:(void(^)(CDOperation* operation)) block {
	CDBlockOperation* operation = [self new];
	operation->_block = [block copy];
	return operation;
}

- (void) main {
	_block(self);
}

@end
