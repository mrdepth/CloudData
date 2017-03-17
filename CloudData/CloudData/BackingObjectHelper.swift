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
	
	func objectID(backingObject: NSManagedObject) -> NSManagedObjectID? {
		guard let store = store else {return nil}
		guard let record = backingObject.value(forKey: CloudRecordProperty) as? CloudRecord else {return nil}
		guard let entity = store.entities?[backingObject.entity.name!] else {return nil}
		
		return store.newObjectID(for: entity, referenceObject: record.recordID!)
	}
	
	func objectID(recordID: String, entityName: String) -> NSManagedObjectID? {
		guard let store = store else {return nil}
		guard let entity = store.entities?[entityName] else {return nil}
		return store.newObjectID(for: entity, referenceObject: recordID)
	}

}

