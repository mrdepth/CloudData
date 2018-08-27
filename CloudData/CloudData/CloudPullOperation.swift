//
//  CloudPullOperation.swift
//  CloudData
//
//  Created by Artem Shimanski on 19.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import Foundation
import CloudKit
import CoreData


class CloudPullOperation: CloudOperation {
	private let store: CloudStore
	private let completionHandler: (CloudPullOperation, Error?) -> Void
	private let backingManagedObjectContext: NSManagedObjectContext
	private let workManagedObjectContext: CloudManagedObjectContext
	private let backingObjectHelper: BackingObjectHelper
	private var cache: [NSManagedObjectID: NSManagedObject]?
	private let entities: [String: NSEntityDescription]?
	
	init(store: CloudStore, completionHandler: @escaping (CloudPullOperation, Error?) -> Void) {
		self.store = store
		self.completionHandler = completionHandler
		self.backingManagedObjectContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
		self.backingManagedObjectContext.parent = store.backingManagedObjectContext

		self.workManagedObjectContext = CloudManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
		self.workManagedObjectContext.persistentStoreCoordinator = store.persistentStoreCoordinator
		self.workManagedObjectContext.mergePolicy = store.mergePolicy
		self.backingObjectHelper = BackingObjectHelper(store: store, managedObjectContext: backingManagedObjectContext)
		self.entities = workManagedObjectContext.persistentStoreCoordinator?.managedObjectModel.entitiesByName
		cache = [:]
		super.init()
	}

	override func main() {
		backingManagedObjectContext.perform {
			let request = NSFetchRequest<CloudMetadata>(entityName: "CloudMetadata")
			guard let metadata = (try? self.backingManagedObjectContext.fetch(request))?.first,
				let recordZoneID = self.store.recordZoneID,
				let database = self.store.database else {
				self.finish()
				self.completionHandler(self, nil)
				return
			}
			
			
			func fetch() {
				let config = CKFetchRecordZoneChangesOperation.ZoneOptions()
				config.previousServerChangeToken = metadata.serverChangeToken
				
				var fetchOperation: CKFetchRecordZoneChangesOperation? = CKFetchRecordZoneChangesOperation(recordZoneIDs: [recordZoneID], optionsByRecordZoneID: [recordZoneID: config])
				
//				var fetchOperation: CKFetchRecordChangesOperation? = CKFetchRecordChangesOperation(recordZoneID: recordZoneID, previousServerChangeToken: metadata.serverChangeToken)
				
				let dispatchGroup = DispatchGroup()
				
				fetchOperation?.recordChangedBlock = { [weak self] record in
					guard let strongSelf = self else {return}
					if strongSelf.entities?[record.recordType] != nil {
						dispatchGroup.enter()
						strongSelf.save(record: record) {
							dispatchGroup.leave()
						}
					}
				}
				
				fetchOperation?.recordWithIDWasDeletedBlock = { [weak self] (recordID, _) in
					guard let strongSelf = self else {return}
					dispatchGroup.enter()
					strongSelf.delete(recordID: recordID) {
						dispatchGroup.leave()
					}
				}
				
				fetchOperation?.recordZoneFetchCompletionBlock = { [weak self] (zoneID, serverChangeToken, clientChangeTokenData, moreComing, operationError) in
					guard let strongSelf = self else {return}
					if moreComing {
						strongSelf.backingManagedObjectContext.perform {
							metadata.serverChangeToken = serverChangeToken
							fetch()
						}
					}
					else {
						if let error = operationError {
							self?.finish(error: error)
							self?.completionHandler(strongSelf, error)
							fetchOperation = nil
						}
						else {
							dispatchGroup.notify(queue: .main) {
								strongSelf.backingManagedObjectContext.perform {
									metadata.serverChangeToken = serverChangeToken
									if strongSelf.backingManagedObjectContext.hasChanges {
										do {
											try strongSelf.backingManagedObjectContext.save()
										}
										catch {
											print("CloudData: \(error)")
										}
									}
									strongSelf.workManagedObjectContext.perform {
										do {
											if strongSelf.workManagedObjectContext.hasChanges {
												try strongSelf.workManagedObjectContext.save()
											}
											strongSelf.finish()
											strongSelf.completionHandler(strongSelf, nil)
										}
										catch {
											strongSelf.finish(error: error)
											strongSelf.completionHandler(strongSelf, error)
										}
										fetchOperation = nil
									}
								}
							}
						}
					}
				}
				
				database.add(fetchOperation!)
			}
			
			fetch()

		}
	}
	
	func save(record: CKRecord, completionHandler: @escaping () -> Void) {

		workManagedObjectContext.perform {
			guard let objectID = self.backingObjectHelper.objectID(recordID: record.recordID.recordName, entityName: record.recordType) else {
				completionHandler()
				return
			}

			
			let lock = NSLock()
			
			func get(objectID: NSManagedObjectID) -> NSManagedObject {
				lock.lock()
				defer {lock.unlock()}
				if let object = self.cache?[objectID] ?? self.workManagedObjectContext.cachedObject(with: objectID) {
					return object
				}
				else {
					let object = NSEntityDescription.insertNewObject(forEntityName: objectID.entity.name!, into: self.workManagedObjectContext)
					self.cache?[objectID] = object
					return object
				}
				
			}
			
			let object = get(objectID: objectID)
			objc_setAssociatedObject(object, CKRecordKey, record, .OBJC_ASSOCIATION_RETAIN_NONATOMIC);

			for property in object.entity.properties {
				if let attribute = property as? NSAttributeDescription {
					let value = attribute.managedValue(from: record, compressed: self.store.binaryDataCompressionAlgorithm)
					object.setValue(value, forKey: attribute.name)
				}
				else if let relationship = property as? NSRelationshipDescription, relationship.shouldSerialize {
					let value = record[relationship.name]
					
					if relationship.isToMany {
						let references = value as? [CKRecord.Reference] ?? {
							guard let reference = value as? CKRecord.Reference else {return []}
							return [reference]
						}()
						var set = [NSManagedObject]()

						for reference in references {
							guard let objectID = relationship.managedReference(from: reference, store: self.store) else {continue}
							let referenceObject = get(objectID: objectID)
							if objc_getAssociatedObject(referenceObject, CKRecordKey) == nil {
								objc_setAssociatedObject(referenceObject, CKRecordKey, CKRecord(recordType: relationship.destinationEntity!.name!, recordID: reference.recordID), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
							}
							set.append(referenceObject)
						}
						if relationship.isOrdered {
							object.setValue(NSOrderedSet(array: set), forKey: relationship.name)
						}
						else {
							object.setValue(NSSet(array: set), forKey: relationship.name)
						}
					}
					else {
						guard let reference = value as? CKRecord.Reference else {continue}
						guard let objectID = relationship.managedReference(from: reference, store: self.store) else {continue}
						let referenceObject = get(objectID: objectID)
						if objc_getAssociatedObject(referenceObject, CKRecordKey) == nil {
							objc_setAssociatedObject(referenceObject, CKRecordKey, CKRecord(recordType: relationship.destinationEntity!.name!, recordID: reference.recordID), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
						}
						object.setValue(referenceObject, forKey: relationship.name)
					}
				}
			}
			completionHandler()
		}
	}

	func delete(recordID: CKRecord.ID, completionHandler: @escaping () -> Void) {
		backingManagedObjectContext.perform {
			if let object = self.backingObjectHelper.backingObject(recordID: recordID.recordName),
				let objectID = self.backingObjectHelper.objectID(backingObject: object) {
				self.workManagedObjectContext.perform {
					if let object = self.workManagedObjectContext.cachedObject(with: objectID) {
						objc_setAssociatedObject(object, CKRecordIDKey, recordID, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
						self.workManagedObjectContext.delete(object)
					}
					completionHandler()
				}
			}
			else {
				completionHandler()
			}
		}
	}
}
