//
//  CloudStore.swift
//  CloudData
//
//  Created by Artem Shimanski on 10.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import Foundation
import CoreData
import CloudKit

public let CloudStoreType: String = "CloudStoreType"

public struct CloudStoreOptions {
	static let containerIdentifierKey: String = "containerIdentifierKey"
	static let databaseScopeKey: String = "databaseScopeKey"
	static let recordZoneKey: String = "recordZoneKey"
	static let mergePolicyType: String = "mergePolicyType"
}

public extension Notification.Name {
	static let CloudStoreDidInitializeCloudAccount = Notification.Name(rawValue: "CloudStoreDidInitializeCloudAccount")
	static let CloudStoreDidFailtToInitializeCloudAccount = Notification.Name(rawValue: "CloudStoreDidFailtToInitializeCloudAccount")
	static let CloudStoreDidStartCloudImport = Notification.Name(rawValue: "CloudStoreDidStartCloudImport")
	static let CloudStoreDidFinishCloudImport = Notification.Name(rawValue: "CloudStoreDidFinishCloudImport")
	static let CloudStoreDidFailCloudImport = Notification.Name(rawValue: "CloudStoreDidFailCloudImport")
}

enum CloudStoreError: Error {
	case unknown
	case invalidRecordZoneID
	case unableToLoadBackingStore
	case invalidDatabaseScope
	case invalidManagedObjectModel
}

public enum CloudStoreScope: Int {
	case `public`
	case `private`
	case shared
}

public let CloudStoreErrorKey = "error"
public let CloudStoreSubscriptionID = "autoUpdate"

open class CloudStore: NSIncrementalStore {

	var entities: [String: NSEntityDescription]?
	
	//MARK: - NSIncrementalStore
	
	override init(persistentStoreCoordinator root: NSPersistentStoreCoordinator?, configurationName name: String?, at url: URL, options: [AnyHashable : Any]? = nil) {
		super.init(persistentStoreCoordinator: root, configurationName: name, at: url, options: options)
	}
	

	
	open override func loadMetadata() throws {
		if backingPersistentStoreCoordinator == nil {
			guard let model = persistentStoreCoordinator?.managedObjectModel else {throw CloudStoreError.invalidManagedObjectModel}
			entities = model.entitiesByName
			backingManagedObjectModel = backingObjectModel(source: model)
			try loadBackingStore()
			
			guard backingPersistentStore != nil else {throw CloudStoreError.unknown}
			backingManagedObjectContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
			backingManagedObjectContext?.persistentStoreCoordinator = backingPersistentStoreCoordinator
		}
	}
	
	//MARK: - Private
	
	private var backingPersistentStoreCoordinator: NSPersistentStoreCoordinator?
	private var backingManagedObjectModel: NSManagedObjectModel?
	private var backingManagedObjectContext: NSManagedObjectContext?
	private var autoPushTimer: Timer?
	private var autoPullTimer: Timer?
	private var accountStatus: CKAccountStatus = .couldNotDetermine
	private var ubiquityIdentityToken: NSCoding?
	private var needsInitialImport: Bool = false
	private var container: CKContainer?
	private var database: CKDatabase?
	private let operationQueue = CloudOperationQueue()
	
	private lazy var databaseScope: CloudStoreScope = {
		if #available(iOS 10.0, *) {
			guard let value = self.options?[CloudStoreOptions.databaseScopeKey] as? Int else {return .private}
			return CloudStoreScope(rawValue: value) ?? .private
		}
		else {
			return .private
		}
	}()
	
	private lazy var recordZoneID: CKRecordZoneID? = {
		guard let zone = (self.options?[CloudStoreOptions.recordZoneKey] as? String) ?? self.url?.deletingPathExtension().lastPathComponent else {return nil}
		
		let ownerName: String
		if #available(iOS 10.0, *) {
			ownerName = CKCurrentUserDefaultName
		} else {
			ownerName = CKOwnerDefaultName
		}
		
		return CKRecordZoneID(zoneName: zone, ownerName: ownerName)
	}()
	private var recordZone: CKRecordZone?

	private lazy var containerIdentifier: String? = self.options?[CloudStoreOptions.containerIdentifierKey] as? String
	
	private lazy var mergePolicyType: NSMergePolicyType = {
		let mergePolicyType = (self.options?[CloudStoreOptions.mergePolicyType] as? NSMergePolicyType) ?? .mergeByPropertyObjectTrumpMergePolicyType
		assert(mergePolicyType != .errorMergePolicyType, "NSErrorMergePolicyType is not supported")
		return mergePolicyType
	}()
	
	
	private func backingObjectModel(source: NSManagedObjectModel) -> NSManagedObjectModel {
		let cloudDataObjectModel = NSManagedObjectModel(contentsOf: Bundle(for: CloudStore.self).url(forResource: "CloudData", withExtension: "momd")!)!
		let backingModel = NSManagedObjectModel(byMerging: [source, cloudDataObjectModel])!
		
		let recordEntity = backingModel.entitiesByName["CDRecord"]!
		var properties = recordEntity.properties
		
		for entity in source.entities {
			let relationship = NSRelationshipDescription()
			relationship.name = entity.name!
			relationship.maxCount = 1
			relationship.deleteRule = .cascadeDeleteRule
			relationship.isOptional = false
			relationship.destinationEntity = backingModel.entitiesByName[entity.name!]
			properties.append(relationship)
			
			let inverseRelationship = NSRelationshipDescription()
			inverseRelationship.name = "_CloudRecord"
			inverseRelationship.deleteRule = .nullifyDeleteRule
			inverseRelationship.maxCount = 1
			inverseRelationship.isOptional = false
			inverseRelationship.destinationEntity = recordEntity
			
			relationship.inverseRelationship = inverseRelationship;
			inverseRelationship.inverseRelationship = relationship;
			
			var p = relationship.destinationEntity?.properties ?? []
			p.append(inverseRelationship)
			relationship.destinationEntity?.properties = p
		}
		recordEntity.properties = properties;
		
		return backingModel;
	}
	
	private var backingPersistentStore: NSPersistentStore?
	
	func loadBackingStore() throws {
		guard let backingPersistentStoreCoordinator = backingPersistentStoreCoordinator else {throw CloudStoreError.unableToLoadBackingStore}

		guard let recordZoneID = recordZoneID else {throw CloudStoreError.invalidRecordZoneID}
		autoPushTimer = nil
		autoPullTimer = nil
		accountStatus = .couldNotDetermine


		self.ubiquityIdentityToken = FileManager.default.ubiquityIdentityToken
		guard databaseScope == .public || ubiquityIdentityToken != nil else {throw CloudStoreError.unableToLoadBackingStore}
		let identifier: String

		if #available(iOS 10.0, *) {
			if let token = ubiquityIdentityToken, databaseScope == .private {
				identifier = UUID(ubiquityIdentityToken: token).uuidString
			}
			else {
				identifier = "local"
			}
		}
		else {
			identifier = "local"
		}
		
		guard let storeURL = url?.appendingPathComponent("\(identifier)/\(containerIdentifier ?? "store")/\(recordZoneID.zoneName).sqlite") else {throw CloudStoreError.unableToLoadBackingStore}
		try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
		
		backingPersistentStore = try! backingPersistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: nil)
		
		let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
		context.persistentStoreCoordinator = backingPersistentStoreCoordinator
		
		context.performAndWait {
			let metadata: CloudMetadata = {
				let request = NSFetchRequest<CloudMetadata>(entityName: "CloudMetadata")
				request.fetchLimit = 1
				return (try? context.fetch(request))?.first
				} () ?? {
					let metadata = CloudMetadata(entity: NSEntityDescription.entity(forEntityName: "CloudMetadata", in: context)!, insertInto: context)
					metadata.recordZoneID = recordZoneID
					return metadata
				}()
			if metadata.uuid == nil {
				metadata.uuid = UUID().uuidString
			}
			if context.hasChanges {
				try? context.save()
			}
			
			self.needsInitialImport = metadata.serverChangeToken == nil
			var m = self.metadata
			m?[NSStoreUUIDKey] = metadata.uuid!
			self.metadata = m
		}
		
		if let containerIdentifier = containerIdentifier {
			self.container = CKContainer(identifier: containerIdentifier)
		}
		else {
			self.container = CKContainer.default()
		}
		try loadDatabase()
	}
	
	private func loadDatabase() throws {
		if #available(iOS 10.0, *) {
			switch databaseScope {
			case .public:
				database = container?.database(with: CKDatabaseScope.public)
			case .private:
				database = container?.database(with: CKDatabaseScope.private)
			case .shared:
				database = container?.database(with: CKDatabaseScope.shared)
			}
			
		} else {
			switch databaseScope {
			case .public:
				database = container?.publicCloudDatabase
			case .private:
				database = container?.privateCloudDatabase
			default:
				throw CloudStoreError.invalidDatabaseScope
			}
		}
		
		operationQueue.addOperation {[weak self] operation in
			guard let strongSelf = self, let container = strongSelf.container else {
				operation.finish()
				return
			}
			container.accountStatus { (status, error) in
				if let error = error {
					NotificationCenter.default.post(name: .CloudStoreDidFailtToInitializeCloudAccount, object: strongSelf, userInfo: [CloudStoreErrorKey : error])
				}
				else {
					strongSelf.accountStatus = status
					strongSelf.loadRecordZone()
				}
				operation.finish(error: error)
			}
		}
	}
	
	private func loadRecordZone() {
		
		func finish(error: Error? = nil) {
			if let error = error {
				NotificationCenter.default.post(name: .CloudStoreDidFailtToInitializeCloudAccount, object: self, userInfo: [CloudStoreErrorKey : error])
			}
			else {
				self.pull()
				self.loadSubscription()
				if self.iCloudIsAvailableForWriting {
					self.autoPushTimer = Timer(timeInterval: 10, target: self, selector: #selector(push), userInfo: nil, repeats: true)
				}
				NotificationCenter.default.post(name: .CloudStoreDidInitializeCloudAccount, object: self, userInfo:nil)
			}
		}
		
		operationQueue.addOperation { [weak self] operation in
			guard let strongSelf = self,
				let recordZoneID = strongSelf.recordZoneID,
				let database = strongSelf.database else {
				operation.finish()
				return
			}
			
			let fetchOperation = CKFetchRecordZonesOperation(recordZoneIDs: [recordZoneID])
			fetchOperation.fetchRecordZonesCompletionBlock = { (zones, error) in
				if let zone = zones?[recordZoneID] {
					strongSelf.recordZone = zone
				}
				else if let zoneError = (error as? CKError)?.partialErrorsByItemID?[recordZoneID] as? CKError,
					case CKError.zoneNotFound = zoneError,
					strongSelf.accountStatus == .available {
					
					let zone = CKRecordZone(zoneID: recordZoneID)
					strongSelf.operationQueue.addOperation { [weak self] operation in
						guard let strongSelf = self else {
							operation.finish()
							return
						}
						
						let modifyOperation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
						modifyOperation.modifyRecordZonesCompletionBlock = { (saved, deleted, error) in
							if let zone = saved?.first {
								strongSelf.recordZone = zone
								finish()
							}
							else {
								finish(error: error ?? CloudStoreError.unknown)
							}
							
							operation.finish()
						}
						
						database.add(modifyOperation)
					}
				}
				else {
					finish(error: error ?? CloudStoreError.unknown)
				}
				operation.finish()
			}
			
			database.add(fetchOperation)
		}
	}
	
	private func pull() {
		
	}
	
	private func loadSubscription() {
		operationQueue.addOperation {[weak self] operation in
			guard let strongSelf = self,
				let recordZoneID = strongSelf.recordZoneID,
				let database = strongSelf.database else {
					operation.finish()
					return
			}
			database.fetch(withSubscriptionID: CloudStoreSubscriptionID) { (subscription, error) in
				if subscription != nil {
					operation.finish(error: error)
				}
				else if let error = error as? CKError, case CKError.unknownItem = error {
					let subscription = CKSubscription(zoneID: recordZoneID, subscriptionID: CloudStoreSubscriptionID, options: [])
					let info = CKNotificationInfo()
					info.shouldSendContentAvailable = true
					subscription.notificationInfo = info
					
					let modifyOperation = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: nil)
					modifyOperation.modifySubscriptionsCompletionBlock = { (saved, deleted, error) in
						operation.finish(error: error)
					}
					
					database.add(modifyOperation)
				}
			}
		}
	}
	
	private var iCloudIsAvailableForReading: Bool {
		if databaseScope == .public {
			return database != nil && recordZone != nil
		}
		else {
			return accountStatus == .available && database != nil && recordZone != nil
		}
	}

	private var iCloudIsAvailableForWriting: Bool {
		return accountStatus == .available && database != nil && recordZone != nil
	}
	
	@objc private func push() {
		
	}
}

