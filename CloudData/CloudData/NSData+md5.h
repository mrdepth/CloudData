//
//  NSData+md5.h
//  CloudData
//
//  Created by Artem Shimanski on 13.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSData (md5)
@property (nonatomic, nonnull, readonly) NSData* md5;
@end
