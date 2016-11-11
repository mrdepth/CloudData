//
//  CDManagedObjectContext.h
//  CloudData
//
//  Created by Artem Shimanski on 11.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import <CoreData/CoreData.h>

@interface CDManagedObjectContext : NSManagedObjectContext

- (nullable __kindof NSManagedObject *)cachedObjectWithID:(NSManagedObjectID*)objectID error:(NSError**)error;

@end
