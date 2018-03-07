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
		guard let url = URL(string: ref) else {return nil}
		guard let objectID = store?.backingPersistentStoreCoordinator?.managedObjectID(forURIRepresentation: url) else {return nil}
		return managedObjectContext.object(with: objectID)
//		let request = NSFetchRequest<NSManagedObject>(entityName: objectID.entity.name!)
//		request.predicate = NSPredicate(format: "\(CloudRecordProperty).recordID == %@", ref)
//		request.fetchLimit = 1
//		return (try? managedObjectContext.fetch(request))?.first
	}
	
	func backingObject(recordID: String) -> NSManagedObject? {
		guard let record = self.record(recordID: recordID) else {return nil}
		guard let recordType = record.recordType else {return nil}
		return record.value(forKey: recordType) as? NSManagedObject
	}
	
	func record(objectID: NSManagedObjectID) -> CloudRecord? {
		return backingObject(objectID: objectID)?.value(forKey: CloudRecordProperty) as? CloudRecord
//		guard let ref = store?.referenceObject(for: objectID) as? String else {return nil}
//		return record(recordID: ref)
	}

	func record(recordID: String) -> CloudRecord? {
		let request = NSFetchRequest<CloudRecord>(entityName: "CloudRecord")
		request.predicate = NSPredicate(format:"recordID == %@", recordID)
		request.fetchLimit = 1
		return (try? managedObjectContext.fetch(request))?.first
	}
	
	func objectID(backingObject: NSManagedObject) -> NSManagedObjectID? {
		guard let store = store else {return nil}
//		guard let record = backingObject.value(forKey: CloudRecordProperty) as? CloudRecord else {return nil}
		guard let entity = store.entities?[backingObject.entity.name!] else {return nil}
		
		return store.newObjectID(for: entity, referenceObject: backingObject.objectID.uriRepresentation().absoluteString)
	}
	
	func objectID(recordID: String, entityName: String) -> NSManagedObjectID? {
		guard let store = store else {return nil}
		guard let record = self.record(recordID: recordID) else {return nil}
		guard let object = record.value(forKey: entityName) as? NSManagedObject else {return nil}
		guard let entity = store.entities?[entityName] else {return nil}
		return store.newObjectID(for: entity, referenceObject: object.objectID.uriRepresentation().absoluteString)
	}
	
	func backingPredicate(from predicate: NSPredicate) -> NSPredicate {
		switch predicate {
		case let predicate as NSComparisonPredicate:
			return NSComparisonPredicate(leftExpression: backingExpression(from: predicate.leftExpression),
			                             rightExpression: backingExpression(from: predicate.rightExpression),
			                             modifier: predicate.comparisonPredicateModifier,
			                             type: predicate.predicateOperatorType,
			                             options: predicate.options)
		case let predicate as NSCompoundPredicate:
			return NSCompoundPredicate(type: predicate.compoundPredicateType,
			                           subpredicates: predicate.subpredicates.map{backingPredicate(from: $0 as! NSPredicate)})
		default:
			return predicate
		}
	}
	
	func backingExpression(from expression: NSExpression) -> NSExpression {
		switch expression.expressionType {
		case .aggregate:
			return NSExpression(forConstantValue: backingObject(from: expression.constantValue))
		case .anyKey:
			return expression
		case .block:
			return expression
		case .conditional:
			return NSExpression(forConditional: backingPredicate(from: expression.predicate), trueExpression: expression.true, falseExpression: expression.false)
		case .constantValue:
			return NSExpression(forConstantValue: backingObject(from: expression.constantValue))
		case .evaluatedObject:
			return expression
		case .function:
			return expression
		case .intersectSet:
			return NSExpression(forIntersectSet: expression.left, with: expression.right)
		case .keyPath:
			return expression
		case .minusSet:
			return NSExpression(forMinusSet: expression.left, with: expression.right)
		case .subquery:
			return expression
		case .unionSet:
			return NSExpression(forUnionSet: expression.left, with: expression.right)
		case .variable:
			return expression
		}
	}
	
	func backingObject(from object: Any?) -> Any? {
		switch object {
		case let managedObject as NSManagedObject:
			return managedObject.objectID.isTemporaryID ? managedObject : backingObject(objectID: managedObject.objectID)
		case let array as NSArray:
			return array.flatMap {backingObject(from: $0)}
		case let set as NSSet:
			return set.flatMap {backingObject(from: $0)}
		case let dic as NSDictionary:
			let out = NSMutableDictionary()
			dic.forEach {
				guard let v = backingObject(from: $0.value) else {return}
				guard let key = $0.key as? NSCopying else {return}
				out.setObject(v, forKey: key)
			}
			return out
		default:
			return object
		}
	}
	
}

