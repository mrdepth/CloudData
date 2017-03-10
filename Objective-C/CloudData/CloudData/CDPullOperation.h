//
//  CDPullOperation.h
//  CloudData
//
//  Created by Artem Shimanski on 10.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "CDOperation.h"

@class CDCloudStore;
@interface CDPullOperation : CDOperation

- (instancetype) initWithStore:(CDCloudStore*) store completionHandler:(void(^)(BOOL moreComing, NSError* error)) block;

@end
