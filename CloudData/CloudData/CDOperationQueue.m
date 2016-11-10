//
//  CDOperationQueue.m
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "CDOperationQueue.h"
#import "CDReachability.h"

@interface CDOperationQueue()
@property (nonatomic, strong) CDReachability* reachability;
@property (nonatomic, strong) NSMutableArray* operations;
@property (nonatomic, strong) NSDate* handleDate;
@property (nonatomic, strong) CDOperation* currentOperation;
@end

@implementation CDOperationQueue

- (id) init {
	if (self = [super init]) {
		self.reachability = [CDReachability reachabilityForInternetConnection];
		[self.reachability startNotifier];
		self.allowsWWAN = YES;
		self.operations = [NSMutableArray new];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityChanged:) name:kCDReachabilityChangedNotification object:self.reachability];
		//[self.operationQueue addObserver:self forKeyPath:@"operationCount" options:0 context:nil];
	}
	return self;
}

- (void) dealloc {
	[self.reachability stopNotifier];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void) addOperation:(CDOperation*) operation {
	@synchronized (self) {
		[self.operations addObject:operation];
	}
	[self handleQueue];
}

- (void) addOperationWithBlock:(void(^)(CDOperation* operation)) block {
	[self addOperation:[CDBlockOperation operationWithBlock:block]];
}

- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
	if ([keyPath isEqualToString:@"isFinished"]) {
		CDOperation* operation = object;
		if (operation.isFinished) {
			@synchronized (self) {
				if ([operation shouldRetry]) {
					NSDate* date = [operation fireDate];
					NSTimeInterval t = -[date timeIntervalSinceNow];
					if (t > 0) {
						dispatch_async(dispatch_get_main_queue(), ^{
							[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleQueue) object:nil];
							[self performSelector:@selector(handleQueue) withObject:nil afterDelay:t];
						});
					}
				}
				else {
					[self.operations removeObject:operation];
					dispatch_async(dispatch_get_main_queue(), ^{
						[self handleQueue];
					});
				}
				self.currentOperation = nil;
			}
		}
	}
}

#pragma mark - Private

- (void) reachabilityChanged:(NSNotification*) note {
	if ([self isReachable])
		[self handleQueue];
	else
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleQueue) object:nil];
}

- (void) handleQueue {
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		@autoreleasepool {
			@synchronized (self) {
				if (!self.currentOperation && self.operations.count > 0 && [self isReachable]) {
					CDOperation* operation = self.operations[0];
					
					if (!operation.fireDate || [operation.fireDate compare:[NSDate date]] == NSOrderedAscending) {
						self.currentOperation = operation;
						[operation start];
					}
					else if ([self.handleDate compare:[NSDate date]] == NSOrderedDescending) {
						NSDate* handleDate = self.handleDate;
						dispatch_async(dispatch_get_main_queue(), ^{
							[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleQueue) object:nil];
							[self performSelector:@selector(handleQueue) withObject:nil afterDelay:-[handleDate timeIntervalSinceNow]];
						});
					}
				}
			}
		}
	});
}

- (BOOL) isReachable {
	CDNetworkStatus networkStatus = [self.reachability currentReachabilityStatus];
	return networkStatus == CDNetworkStatusReachableViaWiFi || (networkStatus == CDNetworkStatusReachableViaWWAN && self.allowsWWAN);
}

- (void) setCurrentOperation:(CDOperation *)currentOperation {
	[_currentOperation removeObserver:self forKeyPath:@"isFinished"];
	_currentOperation = currentOperation;
	[_currentOperation addObserver:self forKeyPath:@"isFinished" options:0 context:nil];
}

@end
