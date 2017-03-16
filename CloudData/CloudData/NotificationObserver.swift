//
//  NotificationObserver.swift
//  CloudData
//
//  Created by Artem Shimanski on 16.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import Foundation

public class NotificationObserver {
	let opaque: NSObjectProtocol
	
	init(opaque: NSObjectProtocol) {
		self.opaque = opaque
	}
	
	deinit {
		NotificationCenter.default.removeObserver(opaque)
	}
}

public extension NotificationCenter {
	
	func addNotificationObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?, using block: @escaping (Notification) -> Swift.Void) -> NotificationObserver {
		let opaque = NotificationCenter.default.addObserver(forName: name, object: obj, queue: queue, using: block)
		return NotificationObserver(opaque: opaque)
	}
}
