//
//  CloudStore.swift
//  CoudData
//
//  Created by Artem Shimanski on 10.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import Foundation
import CoreData

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

open class CloudStore: NSIncrementalStore {
	
	
	override init(persistentStoreCoordinator root: NSPersistentStoreCoordinator?, configurationName name: String?, at url: URL, options: [AnyHashable : Any]? = nil) {
		super.init(persistentStoreCoordinator: root, configurationName: name, at: url, options: options)
	}
}
