//
//  NSRelationshipDescription+CD.m
//  CloudData
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "NSRelationshipDescription+CD.h"

@implementation NSRelationshipDescription (CD)

- (BOOL) shouldSerialize {
	if (self.inverseRelationship) {
		if (self.inverseRelationship.deleteRule == NSCascadeDeleteRule)
			return YES;
		else if (self.deleteRule == NSCascadeDeleteRule)
			return NO;
		else {
			if (self.toMany) {
				if (self.inverseRelationship.toMany)
					return [self.entity.name compare:self.inverseRelationship.name] == NSOrderedAscending;
				else
					return NO;
			}
			else {
				if (self.inverseRelationship.toMany)
					return YES;
				else
					return [self.entity.name compare:self.inverseRelationship.name] == NSOrderedAscending;
			}
		}
	}
	else
		return YES;
}

@end
