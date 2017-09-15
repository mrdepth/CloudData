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

public let CloudStoreType: String = "CloudData.CloudStore"

public struct CloudStoreOptions {
	public static let containerIdentifierKey: String = "containerIdentifierKey"
	public static let databaseScopeKey: String = "databaseScopeKey"
	public static let recordZoneKey: String = "recordZoneKey"
	public static let mergePolicyType: String = "mergePolicyType"
	public static let binaryDataCompressionLevel: String = "binaryDataCompressionLevel"
}

public extension Notification.Name {
	public static let CloudStoreDidInitializeCloudAccount = Notification.Name(rawValue: "CloudStoreDidInitializeCloudAccount")
	public static let CloudStoreDidFailtToInitializeCloudAccount = Notification.Name(rawValue: "CloudStoreDidFailtToInitializeCloudAccount")
	public static let CloudStoreDidStartCloudImport = Notification.Name(rawValue: "CloudStoreDidStartCloudImport")
	public static let CloudStoreDidFinishCloudImport = Notification.Name(rawValue: "CloudStoreDidFinishCloudImport")
	public static let CloudStoreDidFailCloudImport = Notification.Name(rawValue: "CloudStoreDidFailCloudImport")
	public static let CloudStoreDidReceiveRemoteNotification = Notification.Name(rawValue: "CloudStoreDidReceiveRemoteNotification")
}

public enum CloudStoreError: Error {
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

let CloudRecordProperty = "_CloudRecord"
let CKRecordKey = UnsafeRawPointer("CKRecord")
let CKRecordIDKey = UnsafeRawPointer("CKRecordID")
let AutoPushInterval = 15 as TimeInterval

open class CloudStore: NSIncrementalStore {
	
	public class func handleRemoteNotification(userInfo: [AnyHashable: Any]) {
		NotificationCenter.default.post(name: .CloudStoreDidReceiveRemoteNotification, object: nil, userInfo: userInfo)
	}

	var entities: [String: NSEntityDescription]?
	var backingObjectHelper: BackingObjectHelper?
	
	//MARK: - NSIncrementalStore
	
	override init(persistentStoreCoordinator root: NSPersistentStoreCoordinator?, configurationName name: String?, at url: URL, options: [AnyHashable : Any]? = nil) {
		super.init(persistentStoreCoordinator: root, configurationName: name, at: url, options: options)
	}
	
	deinit {
		NotificationCenter.default.removeObserver(self)
	}
	
	open override func loadMetadata() throws {
		if backingPersistentStoreCoordinator == nil {
			guard let model = persistentStoreCoordinator?.managedObjectModel else {throw CloudStoreError.invalidManagedObjectModel}
			entities = model.entitiesByName
			backingManagedObjectModel = backingObjectModel(source: model)
			backingPersistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: backingManagedObjectModel!)
			try loadBackingStore()
			
			guard backingPersistentStore != nil else {throw CloudStoreError.unknown}
			backingManagedObjectContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
			backingManagedObjectContext?.persistentStoreCoordinator = backingPersistentStoreCoordinator
			
			backingObjectHelper = BackingObjectHelper(store: self, managedObjectContext: backingManagedObjectContext!)
			
			let center = NotificationCenter.default
			
			center.addObserver(self, selector: #selector(managedObjectContextDidSave(_:)), name: .NSManagedObjectContextDidSave, object: nil)
			center.addObserver(self, selector: #selector(ubiquityIdentityDidChange(_:)), name: .NSUbiquityIdentityDidChange, object: nil)
			center.addObserver(self, selector: #selector(didReceiveRemoteNotification(_:)), name: .CloudStoreDidReceiveRemoteNotification, object: nil)
			center.addObserver(self, selector: #selector(didBecomeActive(_:)), name: .UIApplicationDidBecomeActive, object: nil)
			center.addObserver(self, selector: #selector(willResignActive(_:)), name: .UIApplicationWillResignActive, object: nil)
		}
	}
	
	open override func execute(_ request: NSPersistentStoreRequest, with context: NSManagedObjectContext?) throws -> Any {
		switch request.requestType {
		case .saveRequestType:
			return try execute(request as! NSSaveChangesRequest, with: context)
		case .fetchRequestType:
			return try execute(request as! NSFetchRequest, with: context)
		default:
			return []
		}
	}
	
	open override func obtainPermanentIDs(for array: [NSManagedObject]) throws -> [NSManagedObjectID] {
		guard let recordZoneID = recordZoneID else {return []}
		var result = [NSManagedObjectID]()
		
		backingManagedObjectContext?.performAndWait {
			for object in array {
				let record = objc_getAssociatedObject(object, CKRecordKey) as? CKRecord
				let cdRecord = NSEntityDescription.insertNewObject(forEntityName: "CloudRecord", into: self.backingManagedObjectContext!) as! CloudRecord
				cdRecord.recordType = object.entity.name
				cdRecord.cache = NSEntityDescription.insertNewObject(forEntityName: "CloudRecordCache", into: self.backingManagedObjectContext!) as? CloudRecordCache
				
				cdRecord.cache?.cachedRecord = record ?? CKRecord(recordType: cdRecord.recordType!, zoneID: recordZoneID)
				cdRecord.recordID = cdRecord.cache?.cachedRecord?.recordID.recordName
				result.append(self.newObjectID(for: object.entity, referenceObject: cdRecord.recordID!))
			}
		}
		return result
	}
	
	open override func newValuesForObject(with objectID: NSManagedObjectID, with context: NSManagedObjectContext) throws -> NSIncrementalStoreNode {
		var values: [String: Any]?
		var version: UInt64 = 0
		
		backingManagedObjectContext?.performAndWait {
			guard let helper = self.backingObjectHelper else {return}
			
			if let context = context as? CloudManagedObjectContext, context.loadFromCache {
				if let record = helper.record(objectID: objectID), let cache = record.cache {
					values = cache.cachedRecord?.nodeValues(store: self, includeToManyRelationships: false)
					version = UInt64(cache.version)
				}
			}
			else if let backingObject = helper.backingObject(objectID: objectID), let entity = self.entities?[backingObject.entity.name!] {
				var dic = [String: Any]()

				for (key, _) in entity.attributesByName {
					if let obj = backingObject.value(forKey: key) {
						dic[key] = obj
					}
				}
				
				for (key, relationship) in entity.relationshipsByName {
					if !relationship.isToMany {
						if let reference = backingObject.value(forKey: key) as? NSManagedObject {
							dic[key] = helper.objectID(backingObject: reference) ?? NSNull()
						}
						else {
							dic[key] = NSNull()
						}
					}
				}
				
				let record = backingObject.value(forKey: CloudRecordProperty) as? CloudRecord
				version = UInt64(record?.version ?? 0)
				values = dic;
			}
		}
		if let values = values {
			return NSIncrementalStoreNode(objectID: objectID, withValues: values, version: version)
		}
		else {
			throw NSError(domain: NSSQLiteErrorDomain, code: NSSQLiteError, userInfo: nil)
		}
	}
	
	open override func newValue(forRelationship relationship: NSRelationshipDescription, forObjectWith objectID: NSManagedObjectID, with context: NSManagedObjectContext?) throws -> Any {
		var result: Any?
		var error: NSError?
		backingManagedObjectContext?.performAndWait {
			guard let helper = self.backingObjectHelper else {return}
			
			if let context = context as? CloudManagedObjectContext, context.loadFromCache {
				if let record = helper.record(objectID: objectID)?.cache?.cachedRecord {
					result = relationship.managedReference(from: record, store: self)
				}
				else {
					error = NSError(domain: NSSQLiteErrorDomain, code: NSSQLiteError, userInfo: nil)
				}
			}
			else if let backingObject = helper.backingObject(objectID: objectID) {
				if relationship.isToMany {
					let value = backingObject.value(forKey: relationship.name)
					if relationship.isOrdered {
						let set = NSMutableOrderedSet()
						for object in value as? NSOrderedSet ?? NSOrderedSet() {
							guard let object = object as? NSManagedObject else {continue}
							guard let objectID = helper.objectID(backingObject: object) else {continue}
							set.add(objectID)
						}
						result = set;
					}
					else {
						var set = Set<NSManagedObjectID>()
						for object in (backingObject.value(forKey: relationship.name) as? Set<NSManagedObject>) ?? Set() {
							guard let objectID = helper.objectID(backingObject: object) else {continue}
							set.insert(objectID)
						}
						result = set;
					}
				}
				else if let object = backingObject.value(forKey: relationship.name) as? NSManagedObject,
					let objectID = helper.objectID(backingObject: object) {
					result = objectID
				}
			}
		}
		if let error = error {
			throw(error)
		}
		
		if let result = result {
			return result
		}
		else if relationship.isToMany {
			return [NSManagedObjectID]()
		}
		else {
			return NSNull()
		}
	}
	
	open override func newObjectID(for entity: NSEntityDescription, referenceObject data: Any) -> NSManagedObjectID {
		return super.newObjectID(for: entity, referenceObject: "id\(data as! String)")
	}
	
	open override func referenceObject(for objectID: NSManagedObjectID) -> Any {
		return (super.referenceObject(for: objectID) as! NSString).substring(from: 2)
	}
	
	//MARK: - Private
	
	var backingPersistentStoreCoordinator: NSPersistentStoreCoordinator?
	private var backingManagedObjectModel: NSManagedObjectModel?
	var backingManagedObjectContext: NSManagedObjectContext?
	private var accountStatus: CKAccountStatus = .couldNotDetermine
	private var ubiquityIdentityToken: (NSObjectProtocol & NSCoding)?
	private var needsInitialImport: Bool = false
	private var container: CKContainer?
	var database: CKDatabase?
	private let operationQueue = CloudOperationQueue()

	private var autoPushTimer: Timer? {
		didSet {
			oldValue?.invalidate()
			if let timer = autoPushTimer {
				RunLoop.main.add(timer, forMode: .defaultRunLoopMode)
			}
		}
	}
	private var autoPullTimer: Timer? {
		didSet {
			oldValue?.invalidate()
			if let timer = autoPullTimer {
				RunLoop.main.add(timer, forMode: .defaultRunLoopMode)
			}
		}
	}

	private lazy var databaseScope: CloudStoreScope = {
		if #available(iOS 10.0, *) {
			guard let value = self.options?[CloudStoreOptions.databaseScopeKey] as? Int else {return .private}
			return CloudStoreScope(rawValue: value) ?? .private
		}
		else {
			return .private
		}
	}()
	
	lazy var binaryDataCompressionLevel: BinaryDataCompressionLevel = {
		return self.options?[CloudStoreOptions.binaryDataCompressionLevel] as? BinaryDataCompressionLevel ?? .none
	}()
	
	lazy var recordZoneID: CKRecordZoneID? = {
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
	
	lazy var mergePolicyType: NSMergePolicyType = {
		let mergePolicyType = (self.options?[CloudStoreOptions.mergePolicyType] as? NSMergePolicyType) ?? .mergeByPropertyObjectTrumpMergePolicyType
		assert(mergePolicyType != .errorMergePolicyType, "NSErrorMergePolicyType is not supported")
		return mergePolicyType
	}()
	
	
	private func backingObjectModel(source: NSManagedObjectModel) -> NSManagedObjectModel {
		let cloudDataObjectModel = NSManagedObjectModel(contentsOf: Bundle(for: CloudStore.self).url(forResource: "CloudData", withExtension: "momd")!)!
		let backingModel = NSManagedObjectModel(byMerging: [source, cloudDataObjectModel])!
		
		let recordEntity = backingModel.entitiesByName["CloudRecord"]!
		var properties = recordEntity.properties
		
		for entity in source.entities {
			let relationship = NSRelationshipDescription()
			relationship.name = entity.name!
			relationship.maxCount = 1
			relationship.deleteRule = .cascadeDeleteRule
			relationship.isOptional = true
			relationship.destinationEntity = backingModel.entitiesByName[entity.name!]
			properties.append(relationship)
			
			let inverseRelationship = NSRelationshipDescription()
			inverseRelationship.name = CloudRecordProperty
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
		
		let names = Set(cloudDataObjectModel.entities.flatMap({$0.name}))
		var cloudEndities = backingModel.entities.filter({names.contains($0.name!)})
		cloudEndities.append(contentsOf: backingModel.entities(forConfigurationName: configurationName) ?? [])
		
		backingModel.setEntities(cloudEndities, forConfigurationName: configurationName)
		
		return backingModel;
	}
	
	private var backingPersistentStore: NSPersistentStore?
	
	//MARK: - Loading
	
	func loadBackingStore() throws {
		guard let backingPersistentStoreCoordinator = backingPersistentStoreCoordinator else {throw CloudStoreError.unableToLoadBackingStore}

		guard let recordZoneID = recordZoneID else {throw CloudStoreError.invalidRecordZoneID}
		autoPushTimer = nil
		autoPullTimer = nil
		accountStatus = .couldNotDetermine

		self.ubiquityIdentityToken = FileManager.default.ubiquityIdentityToken
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
		
		if let containerIdentifier = containerIdentifier {
			self.container = CKContainer(identifier: containerIdentifier)
		}
		else {
			self.container = CKContainer.default()
		}
		
		guard let storeURL = url?.appendingPathComponent("\(identifier)/\(self.container?.containerIdentifier ?? "store")/\(recordZoneID.zoneName).sqlite") else {throw CloudStoreError.unableToLoadBackingStore}
		try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
		
		backingPersistentStore = try backingPersistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: configurationName, at: storeURL, options: nil)
		
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
					self.autoPushTimer = Timer(timeInterval: AutoPushInterval, target: self, selector: #selector(push), userInfo: nil, repeats: true)
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
					finish()
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
	
	//MARK: - Notification handlers
	
	@objc func managedObjectContextDidSave(_ note: Notification) {
		guard let context = note.object as? NSManagedObjectContext else {return}
		guard context != backingManagedObjectContext && context.persistentStoreCoordinator == backingPersistentStoreCoordinator else {return}
		backingManagedObjectContext?.perform {
			self.backingManagedObjectContext?.mergeChanges(fromContextDidSave: note)
		}
	}

	@objc func ubiquityIdentityDidChange(_ note: Notification) {
		guard let token = FileManager.default.ubiquityIdentityToken else {return}
		if !token.isEqual(ubiquityIdentityToken), let store = backingPersistentStore {
			try? backingPersistentStoreCoordinator?.remove(store)
			try? loadBackingStore()
		}
	}

	@objc func didReceiveRemoteNotification(_ note: Notification) {
		guard let info = note.userInfo else {return}
		guard let containerIdentifier = container?.containerIdentifier else {return}
		guard let recordZoneID = recordZoneID else {return}
		
		let notification = CKRecordZoneNotification(fromRemoteNotificationDictionary: info)
		guard notification.containerIdentifier == containerIdentifier && notification.recordZoneID == recordZoneID else {return}
		NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(pull), object: nil)
		perform(#selector(pull), with: nil, afterDelay: 1)
	}

	@objc func didBecomeActive(_ note: Notification) {
		operationQueue.isSuspended = false
		NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(pull), object: nil)
		perform(#selector(pull), with: nil, afterDelay: 3)
		if let timer = autoPushTimer {
			RunLoop.main.add(timer, forMode: .defaultRunLoopMode)
		}
		if let timer = autoPullTimer {
			RunLoop.main.add(timer, forMode: .defaultRunLoopMode)
		}
	}

	@objc func willResignActive(_ note: Notification) {
		operationQueue.isSuspended = true
		NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(pull), object: nil)
		autoPushTimer?.invalidate()
		autoPullTimer?.invalidate()
	}
	
	//MARK: - Push/Pull
	
	lazy var lock = NSLock()
	lazy var isPushing = false
	lazy var isPulling = false

	@objc private func push() {
		if iCloudIsAvailableForWriting {
			do {
				lock.lock(); defer { lock.unlock() }
				guard !isPushing else {return}
				isPushing = true
			}
			
			let operation = CloudPushOperation(store: self) { [weak self] (error, conflicts) in
				guard let strongSelf = self else {return}
				do {
					strongSelf.lock.lock(); defer { strongSelf.lock.unlock() }
					strongSelf.isPushing = false
				}
				if (conflicts?.count ?? 0) > 0 {
					strongSelf.pull()
				}
			}
			self.operationQueue.addOperation(operation)
		}
	}

	@objc private func pull() {
		if iCloudIsAvailableForReading {
			do {
				lock.lock(); defer { lock.unlock() }
				guard !isPulling else {return}
				isPulling = true
			}
			
			if needsInitialImport {
				NotificationCenter.default.post(name: .CloudStoreDidStartCloudImport, object: self)
			}
			
			let operation = CloudPullOperation(store: self) { [weak self] (operation, error) in
				guard let strongSelf = self else {return}
				
				if strongSelf.needsInitialImport {
					if let error = error {
						NotificationCenter.default.post(name: .CloudStoreDidFailCloudImport, object: self, userInfo: [CloudStoreErrorKey: error])
					}
					else {
						NotificationCenter.default.post(name: .CloudStoreDidFinishCloudImport, object: self)
						strongSelf.needsInitialImport = false
					}
				}
				
				do {
					strongSelf.lock.lock(); defer { strongSelf.lock.unlock() }
					strongSelf.isPulling = false
				}
				strongSelf.push()
			}
			
			operationQueue.addOperation(operation)
		}
	}

	//MARK: - Save/Fetch requests
	
	private func execute(_ request: NSSaveChangesRequest, with context: NSManagedObjectContext?) throws -> Any {
		guard let helper = self.backingObjectHelper else {return []}
		guard let recordZoneID = self.recordZoneID else {return []}
		var objects = (request.insertedObjects ?? Set()).union(request.updatedObjects ?? Set())
		
		var err: Error?
		
		backingManagedObjectContext?.performAndWait {
			func backingObjectFrom(_ object: NSManagedObject) -> NSManagedObject? {
				guard let record = helper.record(objectID: object.objectID) else {return nil}
				guard let recordType = record.recordType else {return nil}
				
				return record.value(forKey: recordType) as? NSManagedObject
			}
			
			for object in request.insertedObjects ?? Set() {
				guard let record = helper.record(objectID: object.objectID) else {continue}
				guard let recordType = record.recordType else {continue}
				let bo = NSEntityDescription.insertNewObject(forEntityName: object.entity.name!, into: self.backingManagedObjectContext!)
				bo.setValue(record, forKey: CloudRecordProperty)
				record.setValue(bo, forKey: recordType)
			}
			
			for object in objects {
				let record = helper.record(objectID: object.objectID) ?? {
					let record = NSEntityDescription.insertNewObject(forEntityName: "CloudRecord", into: self.backingManagedObjectContext!) as! CloudRecord
					record.recordType = object.entity.name
					record.cache = NSEntityDescription.insertNewObject(forEntityName: "CloudRecordCache", into: self.backingManagedObjectContext!) as? CloudRecordCache
					
					record.cache?.cachedRecord = CKRecord(recordType: record.recordType!, zoneID: recordZoneID)
					record.recordID = record.cache?.cachedRecord?.recordID.recordName
					return record
				}()
				guard let recordType = record.recordType else {continue}
				let backingObject = record.value(forKey: recordType) as? NSManagedObject ?? {
					let backingObject = NSEntityDescription.insertNewObject(forEntityName: object.entity.name!, into: self.backingManagedObjectContext!)
					backingObject.setValue(record, forKey: CloudRecordProperty)
					return backingObject
				}()
				
				let propertiesByName = object.entity.propertiesByName
				
				object.changedValues().forEach{ (key, value) in
					guard let property = propertiesByName[key] else {return}
					if property is NSAttributeDescription {
						backingObject.setValue(value, forKey: key)
					}
					else if let relationship = property as? NSRelationshipDescription {
						if relationship.isToMany {
							if relationship.isOrdered {
								let set = NSMutableOrderedSet()
								for object in value as? NSOrderedSet ?? NSOrderedSet() {
									guard let object = object as? NSManagedObject else {continue}
									guard let reference = backingObjectFrom(object) else {continue}
									set.add(reference)
								}
								backingObject.setValue(set, forKey: key)
							}
							else {
								var set = Set<NSManagedObject>()
								for object in value as? Set<NSManagedObject> ?? Set() {
									guard let reference = backingObjectFrom(object) else {continue}
									set.insert(reference)
								}
								backingObject.setValue(set, forKey: key)
							}
						}
						else if let object = value as? NSManagedObject {
							backingObject.setValue(backingObjectFrom(object), forKey: key)
						}
						else {
							backingObject.setValue(nil, forKey: key)
						}
					}
				}

				if let ckRecord = objc_getAssociatedObject(object, CKRecordKey) as? CKRecord {
					record.cache?.cachedRecord = ckRecord
					record.cache?.version = record.version + 1
//					if record.version == record.cache?.version {
//						record.cache?.version += 1
//					}
					objc_setAssociatedObject(object, CKRecordKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
				}
				record.version += 1
			}
			
			for object in request.deletedObjects ?? Set() {
				guard let record = helper.record(objectID: object.objectID) else {continue}
				guard let recordType = record.recordType else {continue}
				if let backingObject = record.value(forKey: recordType) as? NSManagedObject {
					self.backingManagedObjectContext?.delete(backingObject)
				}
				
				if (objc_getAssociatedObject(object, CKRecordIDKey) as? CKRecord) != nil {
					self.backingManagedObjectContext?.delete(record)
				}
				record.version = 0
			}
			
			if self.backingManagedObjectContext?.hasChanges == true {
				do {
					try self.backingManagedObjectContext?.save()
				}
				catch {
					err = error
				}
				
			}
		}
		if let error = err {
			throw error
		}
		return []
	}
	
	private func execute(_ request: NSFetchRequest<NSFetchRequestResult>, with context: NSManagedObjectContext?) throws -> Any {
		
		guard let backingManagedObjectModel = backingManagedObjectModel else {throw CloudStoreError.invalidManagedObjectModel}
		guard let context = context else {return []}
		
		var objects = [Any]()
		let resultType = request.resultType
		
		var err: Error?
		
		backingManagedObjectContext?.performAndWait {
			do {
				let backingRequest = request.copy() as! NSFetchRequest<NSFetchRequestResult>
				backingRequest.entity = backingManagedObjectModel.entitiesByName[request.entityName ?? request.entity!.name!]
				if let predicate = backingRequest.predicate {
					backingRequest.predicate = self.backingObjectHelper?.backingPredicate(from: predicate)
				}
				
				if backingRequest.resultType == .managedObjectIDResultType {
					backingRequest.resultType = .managedObjectResultType
				}

				let result = try self.backingManagedObjectContext!.fetch(backingRequest)
				switch resultType {
				case NSFetchRequestResultType.managedObjectResultType, NSFetchRequestResultType.managedObjectIDResultType:
					for object in result {
						guard let record = (object as? NSObject)?.value(forKey: CloudRecordProperty) as? CloudRecord else {continue}
						guard let recordID = record.recordID else {continue}
						objects.append(self.newObjectID(for: request.entity!, referenceObject: recordID))
					}
				case NSFetchRequestResultType.dictionaryResultType, NSFetchRequestResultType.countResultType:
					objects = result
				default:
					break
				}
			}
			catch {
				err = error
			}
		}
		if let error = err {
			throw error
		}
		else {
			var result = [Any]()
			
			switch resultType {
			case NSFetchRequestResultType.managedObjectResultType:
				for objectID in objects {
					guard let objectID = objectID as? NSManagedObjectID else {continue}
					result.append(context.object(with: objectID))
				}
			default:
				result = objects
			}
			
			return result
		}
	}

}

