//
//  Extensions.swift
//  CloudData
//
//  Created by Artem Shimanski on 13.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import Foundation
import CoreData
import CloudKit

extension UUID {
	init(ubiquityIdentityToken token: NSCoding) {
		let data = NSKeyedArchiver.archivedData(withRootObject: token) as NSData
		let md5 = data.md5
		
		let uuid = md5.withUnsafeBytes { b -> uuid_t in
			uuid_t(b[0], b[1], b[2], b[3],
			       b[4], b[5], b[6], b[7],
			       b[8], b[9], b[10], b[11],
			       b[12], b[13], b[14], b[15])
		}
		
		self = UUID(uuid: uuid)
	}
}



extension NSAttributeDescription {

	func transformedValue(_ value: Any?) -> Any? {
		if attributeType == .transformableAttributeType {
			if let valueTransformerName = valueTransformerName {
				return ValueTransformer(forName: NSValueTransformerName(rawValue: valueTransformerName))?.transformedValue(value)
			}
			else if let value = value {
				return NSKeyedArchiver.archivedData(withRootObject: value)
			}
		}
		return value
	}
	
	func reverseTransformedValue(_ value: Any?) -> Any? {
		guard !(value is NSNull) else {return nil}
		switch attributeType {
		case .undefinedAttributeType, .objectIDAttributeType:
			assert(false, "Invalid attribute type \(attributeType)")
		case .integer16AttributeType,
		     .integer32AttributeType,
		     .integer64AttributeType,
		     .decimalAttributeType,
		     .doubleAttributeType,
		     .floatAttributeType,
		     .booleanAttributeType:
			return value ?? self.defaultValue
		case .stringAttributeType,
		     .dateAttributeType,
		     .binaryDataAttributeType:
			return value
		case .transformableAttributeType:
			if let valueTransformerName = valueTransformerName {
				return ValueTransformer(forName: NSValueTransformerName(rawValue: valueTransformerName))?.reverseTransformedValue(value)
			}
			else if let data = value as? Data {
				return NSKeyedUnarchiver.unarchiveObject(with: data)
			}
		}
		return value
	}
	
	func ckRecordValue(from backingObject: NSManagedObject) -> CKRecordValue? {
		return transformedValue(backingObject.value(forKey: self.name)) as? CKRecordValue
	}
	
	func managedValue(from record: CKRecord) -> Any? {
		return reverseTransformedValue(record[name])
	}

}

extension NSRelationshipDescription {
	
	@nonobjc var shouldSerialize: Bool {
		if let inverseRelationship = inverseRelationship {
			if inverseRelationship.deleteRule == .cascadeDeleteRule {
				return true
			}
			else if deleteRule == .cascadeDeleteRule {
				return false
			}
			else {
				if isToMany {
					if inverseRelationship.isToMany {
						return entity.name! < inverseRelationship.name
					}
					else {
						return false
					}
				}
				else {
					if inverseRelationship.isToMany {
						return true
					}
					else {
						return entity.name! < inverseRelationship.name
					}
				}
			}
		}
		else {
			return true
		}
	}
	
	@nonobjc func ckReference(from backingObject: NSManagedObject, recordZoneID: CKRecordZoneID) -> Any? {
		var result: Any?
		
		backingObject.managedObjectContext?.performAndWait {
			let action: CKReferenceAction = self.inverseRelationship?.deleteRule == .cascadeDeleteRule ? .deleteSelf : .none
			
			let value = backingObject.value(forKey: self.name)
			
			if self.isToMany {
				guard let value = value as? [NSManagedObject] else {return}
				var references = [CKReference]()
				for object in value {
					guard let record = object.value(forKey: CloudRecordProperty) as? CloudRecord else {continue}
					let reference = CKReference(recordID: CKRecordID(recordName: record.recordID!, zoneID: recordZoneID), action: action)
					references.append(reference)
				}
				result = references
			}
			else if let object = value as? NSManagedObject {
				guard let record = object.value(forKey: CloudRecordProperty) as? CloudRecord else {return}
				result = CKReference(recordID: CKRecordID(recordName: record.recordID!, zoneID: recordZoneID), action: action)
			}
		}
		
		return result
	}
	
	@nonobjc func managedReference(from record: CKRecord, store: CloudStore) -> Any? {
		let value = record[name]
		if isToMany {
			guard let value = value as? [CKReference] else {return NSNull()}
			
			var set = Set<NSManagedObjectID>()

			for reference in value {
				if let objectID = managedReference(from: reference, store: store) {
					set.insert(objectID)
				}
			}
			return set
		}
		else {
			if let reference = value as? CKReference ?? (value as? [CKReference])?.last {
				return managedReference(from: reference, store: store)
			}
			else {
				return NSNull()
			}
		}

	}
	
	@nonobjc func managedReference(from reference: CKReference, store: CloudStore) -> NSManagedObjectID? {
		return store.backingObjectHelper?.objectID(recordID: reference.recordID.recordName, entityName: destinationEntity!.name!)
	}

}

extension NSManagedObject {
	

}


extension CKRecord {
	
	func changedValues(object: NSManagedObject, entity: NSEntityDescription) -> [String: Any] {
		assert(recordType == object.entity.name)
		var diff = [String: Any]()
		
		for property in entity.properties {
			if let attribute = property as? NSAttributeDescription {
				let value1: NSObjectProtocol = attribute.ckRecordValue(from: object) ?? NSNull()
				let value2: NSObjectProtocol = self[attribute.name] ?? NSNull()
				if !value1.isEqual(value2) {
					diff[attribute.name] = value1
				}
			}
			else if let relationship = property as? NSRelationshipDescription {
				if relationship.shouldSerialize {
					let value1: NSObjectProtocol = relationship.ckReference(from: object, recordZoneID: self.recordID.zoneID) as? NSObjectProtocol ?? NSNull()
					let value2: NSObjectProtocol = self[relationship.name] ?? NSNull()
					if !value1.isEqual(value2) {
						diff[relationship.name] = value1
					}
				}
			}
		}
		return diff
	}
	
	func nodeValues(store: CloudStore, includeToManyRelationships: Bool) -> [String: Any] {
		guard let entity = store.entities?[recordType] else {return [:]}
		var values = [String: Any]()
		
		for property in entity.properties {
			if let attribute = property as? NSAttributeDescription {
				if let value = attribute.managedValue(from: self) {
					values[attribute.name] = value
				}
			}
			else if let relationship = property as? NSRelationshipDescription {
				if includeToManyRelationships || !relationship.isToMany {
					if let value = relationship.managedReference(from: self, store: store) {
						values[relationship.name] = value
					}
				}
			}
		}
		
		return values
	}
}
