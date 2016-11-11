//
//  CDManagedObjectContext.m
//  CloudData
//
//  Created by Artem Shimanski on 11.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "CDManagedObjectContext.h"

@interface CDManagedObjectContext()
@property (nonatomic, assign) BOOL loadFromCache;
@end

@implementation CDManagedObjectContext

- (nullable __kindof NSManagedObject *)cachedObjectWithID:(NSManagedObjectID*)objectID error:(NSError**)error {
	self.loadFromCache = YES;
	id object = [self existingObjectWithID:objectID error:error];
	self.loadFromCache = NO;
	return object;
}

@end
