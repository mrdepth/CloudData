//
//  BackingObjectHelper.swift
//  CloudData
//
//  Created by Artem Shimanski on 13.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import Foundation
import CoreData

struct BackingObjectHelper {
	weak var store: CloudStore?
	let managedObjectContext: NSManagedObjectContext
	
	func backingObject(objectID: NSManagedObjectID) -> NSManagedObject? {
		guard let ref = store?.referenceObject(for: objectID) as? String else {return nil}
		let request = NSFetchRequest<NSManagedObject>(entityName: objectID.entity.name!)
		request.predicate = NSPredicate(format: "\(CloudRecordProperty).recordID == %@", ref)
		request.fetchLimit = 1
		return (try? managedObjectContext.fetch(request))?.first
	}
	
	func backingObject(recordID: String) -> NSManagedObject? {
		guard let record = self.record(recordID: recordID) else {return nil}
		guard let recordType = record.recordType else {return nil}
		return record.value(forKey: recordType) as? NSManagedObject
	}
	
	func record(objectID: NSManagedObjectID) -> CloudRecord? {
		guard let ref = store?.referenceObject(for: objectID) as? String else {return nil}
		return record(recordID: ref)
	}

	func record(recordID: String) -> CloudRecord? {
		let request = NSFetchRequest<CloudRecord>(entityName: "CDRecord")
		request.predicate = NSPredicate(format:"recordID == %@", recordID)
		request.fetchLimit = 1
		return (try? managedObjectContext.fetch(request))?.first
	}
	
//	func objectID(backingObject: NSManagedObject) -> NSManagedObject? {
//		guard let record = backingObject.value(forKey: "_CloudRecord") as? CloudRecord else {return nil}
//		return store.newObjectID(for: s, referenceObject: <#T##Any#>)
//	}
//	
//	func objectID(recordID: String, entityName: String) -> NSManagedObject? {
//	}

}

