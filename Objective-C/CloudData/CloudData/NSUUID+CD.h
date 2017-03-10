//
//  NSUUID+CD.h
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSUUID (CD)

+ (instancetype) UUIDWithUbiquityIdentityToken:(id<NSCoding>) token;

@end
