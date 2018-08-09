//
//  CloudPushOperation.swift
//  CloudData
//
//  Created by Artem Shimanski on 19.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import Foundation
import CloudKit
import CoreData

class CloudPushOperation: CloudOperation {
	private let store: CloudStore
	private let completionHandler: (Error?, [CKRecord]?) -> Void
	private let context: NSManagedObjectContext
	
	private var databaseOperation: CKModifyRecordsOperation?
	private var cache: [CKRecordID: CloudRecord]?
	
	init(store: CloudStore, completionHandler: @escaping (Error?, [CKRecord]?) -> Void) {
		self.store = store
		self.completionHandler = completionHandler
		self.context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
		self.context.persistentStoreCoordinator = store.backingPersistentStoreCoordinator
		self.context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
		super.init()
	}
	
	override func main() {
		context.perform {
			self.prepare()
			if let databaseOperation = self.databaseOperation, let database = self.store.database {
				let cache = self.cache
				let context = self.context
				let dispatchGroup = DispatchGroup()
				var conflicts = [CKRecord]()
				
				databaseOperation.perRecordCompletionBlock = { (record, error) in
					if let error = error {
						switch (error as? CKError)?.code {
						case .serverRecordChanged?:
							conflicts.append(record)
							dispatchGroup.enter()
							context.perform {
								let cdRecord = cache?[record.recordID]
								cdRecord?.cache?.cachedRecord = record
								dispatchGroup.leave()
							}
						case .networkUnavailable?,
						     .networkFailure?,
						     .serviceUnavailable?,
						     .requestRateLimited?:
							break
						default:
							print ("CloudPushOperation: \(error)")
							dispatchGroup.enter()
							context.perform {
								let cdRecord = cache?[record.recordID]
								cdRecord?.cache?.version = cdRecord!.version
								dispatchGroup.leave()
							}

						}
					}
					else {
						dispatchGroup.enter()
						context.perform {
							let cdRecord = cache?[record.recordID]
							cdRecord?.cache?.cachedRecord = record
							cdRecord?.cache?.version = cdRecord!.version
							dispatchGroup.leave()
						}
					}
				}
				
				databaseOperation.modifyRecordsCompletionBlock = { [weak self] (saved, deleted, error) in
					dispatchGroup.notify(queue: .main) {
						context.perform {
							for recordID in deleted ?? [] {
								guard let record = cache?[recordID] else {continue}
								context.delete(record)
							}
							if context.hasChanges {
								try? context.save()
							}
							self?.completionHandler(error, conflicts.count > 0 ? conflicts : nil)
							self?.finish(error: error)
						}
					}
				}
				
				database.add(databaseOperation)
			}
			else {
				if self.context.hasChanges {
					try? self.context.save()
				}
				self.finish()
				self.completionHandler(nil, nil)
			}
		}
	}
	
	func prepare() {
		let request = NSFetchRequest<CloudRecord>(entityName: "CloudRecord")
		request.predicate = NSPredicate(format: "version > cache.version OR version == 0")
		var recordsToSave = [CKRecord]()
		var recordsToDelete = [CKRecordID]()
		var cache = [CKRecordID: CloudRecord]()
		let compressionAlgorithm = store.binaryDataCompressionAlgorithm
		
		for record in (try? context.fetch(request)) ?? [] {
			guard let recordID = record.cache?.cachedRecord?.recordID else {
				continue
			}
			if record.version == 0 {
				if (record.cache?.version ?? 0) > 0 {
					cache[recordID] = record
					recordsToDelete.append(recordID)
				}
				else {
					context.delete(record)
				}
			}
			else if let recordType = record.recordType {
				guard let backingObject = record.value(forKey: recordType) as? NSManagedObject else {continue}
				guard let entity = store.entities?[backingObject.entity.name!] else {continue}
				let changedValues = record.cache?.cachedRecord?.changedValues(object: backingObject, entity: entity) ?? [:]
				if (changedValues.count > 0) {
					cache[recordID] = record
					if let ckRecord = record.cache?.cachedRecord?.copy() as? CKRecord {
						for (key, value) in changedValues {
							switch value {
							case is NSNull:
								ckRecord[key] = nil as CKRecordValue?
							case let data as Data:
								if let compressionAlgorithm = compressionAlgorithm {
									ckRecord[key] = ((try? data.compressed(algorithm: compressionAlgorithm)) ?? data) as NSData
								}
								else {
									ckRecord[key] = data as NSData
								}
							default:
								ckRecord[key] = value as? CKRecordValue
							}
						}
						recordsToSave.append(ckRecord)
					}
					
				}
				else {
					record.cache?.version = record.version
				}
			}

		}
		
		if recordsToSave.count > 0 || recordsToDelete.count > 0 {
			databaseOperation = CKModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: recordsToDelete)
			self.cache = cache
		}
	}
}
