//
//  CloudManagedObjectContext.swift
//  CloudData
//
//  Created by Artem Shimanski on 17.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import Foundation
import CoreData

class CloudManagedObjectContext: NSManagedObjectContext {
	var loadFromCache: Bool = false
	
	func cachedObject(with objectID: NSManagedObjectID) -> NSManagedObject {
		loadFromCache = true
		let result = object(with: objectID)
		loadFromCache = false
		return result
	}
}
