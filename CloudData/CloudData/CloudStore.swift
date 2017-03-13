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

extension Notification.Name {
	static let CloudStoreDidInitializeCloudAccount = Notification.Name(rawValue: "CloudStoreDidInitializeCloudAccount")
	static let CloudStoreDidFailtToInitializeCloudAccount = Notification.Name(rawValue: "CloudStoreDidFailtToInitializeCloudAccount")
	static let CloudStoreDidStartCloudImport = Notification.Name(rawValue: "CloudStoreDidStartCloudImport")
	static let CloudStoreDidFinishCloudImport = Notification.Name(rawValue: "CloudStoreDidFinishCloudImport")
	static let CloudStoreDidFailCloudImport = Notification.Name(rawValue: "CloudStoreDidFailCloudImport")
}

enum CloudStoreError: Error {
	case invalidRecordZoneID
	case unableToLoadBackingStore
}

public enum CloudStoreScope: Int {
	case `public`
	case `private`
	case shared
}

open class CloudStore: NSIncrementalStore {

	
	//MARK: - NSIncrementalStore
	
	override init(persistentStoreCoordinator root: NSPersistentStoreCoordinator?, configurationName name: String?, at url: URL, options: [AnyHashable : Any]? = nil) {
		super.init(persistentStoreCoordinator: root, configurationName: name, at: url, options: options)
	}
	

	
	open override func loadMetadata() throws {
		if backingPersistentStoreCoordinator == nil {
			
		}
	}
	
	//MARK: - Private
	
	private var backingPersistentStoreCoordinator: NSPersistentStoreCoordinator?
	private var autoPushTimer: Timer?
	private var autoPullTimer: Timer?
	private var accountStatus: CKAccountStatus = .couldNotDetermine
	private var ubiquityIdentityToken: NSCoding?
	private var needsInitialImport: Bool = false
	private var container: CKContainer?
	
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
		loadDatabase()
	}
	
	private func loadDatabase() {
	
	}
}

