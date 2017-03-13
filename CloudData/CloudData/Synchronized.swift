//
//  Synchronized.swift
//  CloudData
//
//  Created by Artem Shimanski on 13.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import Foundation

public func synchronized<ReturnType>(_ lockToken: AnyObject, action: () -> ReturnType) -> ReturnType {
	return synchronized(lockToken: lockToken, action: action())
}

public func synchronized<ReturnType>(lockToken: AnyObject, action: @autoclosure () -> ReturnType) -> ReturnType {
	defer { objc_sync_exit(lockToken) }
	objc_sync_enter(lockToken)
	return action()
}
