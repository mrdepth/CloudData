//
//  CDPushOperation.h
//  CloudData
//
//  Created by Artem Shimanski on 10.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "CDOperation.h"

@class CDCloudStore, CKRecord;
@interface CDPushOperation : CDOperation

- (instancetype) initWithStore:(CDCloudStore*) store completionHandler:(void(^)(NSError* error, NSArray<CKRecord*>* conflicts)) block;

@end
