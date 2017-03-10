//
//  CloudOperation.swift
//  CoudData
//
//  Created by Artem Shimanski on 10.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import Foundation
import CloudKit

let CloudOperationRetryLimit = 3

class CloudOperation: Operation {
	
	var shouldRetry: Bool {
		get {
			return fireDate != nil
		}
	}
	
	private(set) var fireDate: Date?
	
	func finish(error: Error? = nil) {
		switch error {
		case CKError.networkUnavailable?,
		     CKError.networkFailure?,
		     CKError.serviceUnavailable?,
		     CKError.requestRateLimited?,
		     CKError.notAuthenticated?:
			if _retryCounter < CloudOperationRetryLimit {
				_retryCounter += 1
				let retryAfter = (error as? CKError)?.retryAfterSeconds ?? 3.0
				fireDate = Date(timeIntervalSinceNow: retryAfter)
				print("Error: \(error!). Retry after \(retryAfter)")
			}
		default:
			break
		}
	}
	
	func retry(after: TimeInterval) {
		fireDate = Date(timeIntervalSinceNow: after)
		finish(error: nil)
	}
	
	//MARK - Operation
	
	private var _executing: Bool = false
	private var _finished: Bool = false
	private var _retryCounter: Int = 0

	override var isAsynchronous: Bool {
		return true
	}
	
	override var isExecuting: Bool {
		return _executing
	}
	
	override var isFinished: Bool {
		return _finished
	}
	
	override func start() {
		fireDate = nil
		willChangeValue(forKey: "isExecuting")
		_executing = true
		_finished = false
		didChangeValue(forKey: "isExecuting")
		main()
	}
	
	override func main() {
		finish(error: nil)
	}
	
}

class CloudBlockOperation: CloudOperation {

	let block: (CloudOperation) -> Void
	
	init(block: @escaping (CloudOperation) -> Void) {
		self.block = block
		super.init()
	}
	
	override func main() {
		block(self)
	}

}
