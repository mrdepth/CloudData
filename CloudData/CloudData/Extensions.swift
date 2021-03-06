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
		let data = NSKeyedArchiver.archivedData(withRootObject: token)
		let md5 = data.md5()
		let uuid = md5.withUnsafeBytes { ptr -> uuid_t in
			let b = ptr.bindMemory(to: UInt8.self)
			return uuid_t(b[0], b[1], b[2], b[3],
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
	
	func reverseTransformedValue(_ value: Any?, compressed withAlgorithm: CompressionAlgorithm?) -> Any? {
		var value = value
		guard !(value is NSNull) else {return nil}
		if let data = value as? Data {
			if let algorithm = withAlgorithm {
				value = (try? data.decompressed(algorithm: algorithm)) ?? data
			}
			else {
				value = data
			}
		}
		
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
		     .binaryDataAttributeType,
		     .UUIDAttributeType,
		     .URIAttributeType:
			return value
		case .transformableAttributeType:
			if let valueTransformerName = valueTransformerName {
				return ValueTransformer(forName: NSValueTransformerName(rawValue: valueTransformerName))?.reverseTransformedValue(value)
			}
			else if let data = value as? Data {
				return NSKeyedUnarchiver.unarchiveObject(with: data)
			}
		@unknown default:
			return value
		}
		return value
	}
	
	func ckRecordValue(from backingObject: NSManagedObject) -> CKRecordValue? {
		return transformedValue(backingObject.value(forKey: self.name)) as? CKRecordValue
	}
	
	func managedValue(from record: CKRecord, compressed withAlgorithm: CompressionAlgorithm?) -> Any? {
		return reverseTransformedValue(record[name], compressed: withAlgorithm)
	}

}

extension NSRelationshipDescription {
	
	@nonobjc var shouldSerialize: Bool {
		return true
		/*if let inverseRelationship = inverseRelationship {
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
		}*/
	}
	
	@nonobjc func ckReference(from backingObject: NSManagedObject, recordZoneID: CKRecordZone.ID) -> Any? {
		var result: Any?
		
		backingObject.managedObjectContext?.performAndWait {
			let action: CKRecord.Reference.Action = self.inverseRelationship?.deleteRule == .cascadeDeleteRule ? .deleteSelf : .none
			
			let value = backingObject.value(forKey: self.name)
			
			if self.isToMany {
				if self.isOrdered {
					guard let value = value as? NSOrderedSet else {return}
					var references = [CKRecord.Reference]()
					for object in value {
						guard let object = object as? NSManagedObject else {continue}
						guard let record = object.value(forKey: CloudRecordProperty) as? CloudRecord else {continue}
						let reference = CKRecord.Reference(recordID: CKRecord.ID(recordName: record.recordID!, zoneID: recordZoneID), action: action)
						references.append(reference)
					}
					result = references.count > 0 ? references : NSNull()
				}
				else {
					guard let value = value as? Set<NSManagedObject> else {return}
					var references = Set<CKRecord.Reference>()
					for object in value {
						guard let record = object.value(forKey: CloudRecordProperty) as? CloudRecord else {continue}
						let reference = CKRecord.Reference(recordID: CKRecord.ID(recordName: record.recordID!, zoneID: recordZoneID), action: action)
						references.insert(reference)
					}
					
					result = references.count > 0 ? references.sorted(by: {$0.recordID.recordName < $1.recordID.recordName}) : NSNull()
				}
			}
			else if let object = value as? NSManagedObject {
				guard let record = object.value(forKey: CloudRecordProperty) as? CloudRecord else {return}
				result = CKRecord.Reference(recordID: CKRecord.ID(recordName: record.recordID!, zoneID: recordZoneID), action: action)
			}
		}
		
		return result
	}
	
	@nonobjc func managedReference(from record: CKRecord, store: CloudStore) -> Any? {
		let value = record[name]
		if isToMany {
			guard let value = value as? [CKRecord.Reference] else {return NSNull()}
			
			var set = [NSManagedObjectID]()

			for reference in value {
				if let objectID = managedReference(from: reference, store: store) {
					set.append(objectID)
				}
			}
			return isOrdered ? NSOrderedSet(array: set) : NSSet(array: set)
		}
		else {
			if let reference = value as? CKRecord.Reference ?? (value as? [CKRecord.Reference])?.last {
				return managedReference(from: reference, store: store)
			}
			else {
				return NSNull()
			}
		}

	}
	
	@nonobjc func managedReference(from reference: CKRecord.Reference, store: CloudStore) -> NSManagedObjectID? {
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
				if let value = attribute.managedValue(from: self, compressed: store.binaryDataCompressionAlgorithm) {
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
