//
//  CloudOperationQueue.swift
//  CloudData
//
//  Created by Artem Shimanski on 10.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import Foundation

class CloudOperationQueue: NSObject {
	var allowsWWAN: Bool = true
	private let reachability = Reachability()
	private(set) var operations = [CloudOperation]()
	private var handleDate: Date?
	
	private var currentOperation: CloudOperation? {
		didSet {
			oldValue?.removeObserver(self, forKeyPath: "isFinished")
			currentOperation?.addObserver(self, forKeyPath: "isFinished", options: [], context: nil)
		}
	}
	
	var isSuspended: Bool = false {
		didSet {
			if isSuspended == false {
				handleQueue()
			}
		}
	}
	
	private var observer: NotificationObserver?
	
	override init() {
		super.init()
		
		if let reachability = reachability, reachability.startNotifier() {
			observer = NotificationCenter.default.addNotificationObserver(forName: .ReachabilityChanged, object: reachability, queue: .main) {[weak self] _ in
				guard let strongSelf = self else {return}
				if strongSelf.isReachable {
					strongSelf.handleQueue()
				}
				else {
					NSObject.cancelPreviousPerformRequests(withTarget: strongSelf, selector: #selector(CloudOperationQueue.handleQueue), object: nil)
				}
			}
		}
	}
	
	
	func addOperation(_ operation: CloudOperation) {
		synchronized(self) {
			self.operations.append(operation)
		}
		handleQueue()
	}
	
	func addOperation(block: @escaping (CloudOperation) -> Void) {
		addOperation(CloudBlockOperation(block: block))
	}
	
	override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
		if keyPath == "isFinished", let operation = object as? CloudOperation, operation.isFinished {
			synchronized(self) {
				if operation.shouldRetry, let date = operation.fireDate {
					let t = date.timeIntervalSinceNow
					if t > 0 {
						DispatchQueue.main.async {
							NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(CloudOperationQueue.handleQueue), object: nil)
							self.perform(#selector(CloudOperationQueue.handleQueue), with: nil, afterDelay: t)
						}
					}
				}
				else {
					if let i = operations.index(of: operation) {
						operations.remove(at: i)
					}
					DispatchQueue.main.async {
						self.handleQueue()
					}
				}
				self.currentOperation = nil;
			}
		}
	}
	
	private var isReachable: Bool {
		if let status = reachability?.reachabilityStatus {
			return status == .reachableViaWiFi || (status == .reachableViaWWAN && allowsWWAN)
		}
		else {
			return true
		}
	}
	
	@objc private func handleQueue() {
		guard !isSuspended else {return}
		DispatchQueue.global(qos: .default).async {
			autoreleasepool {
				synchronized(self) {
					guard self.currentOperation == nil, let operation = self.operations.first, self.isReachable else {return}
					if let fireDate = operation.fireDate, fireDate <= Date() {
						self.currentOperation = operation
						operation.start()
					}
					else if let handleDate = self.handleDate, handleDate > Date() {
						let t = -handleDate.timeIntervalSinceNow
						self.perform(#selector(CloudOperationQueue.handleQueue), with: nil, afterDelay: t)
					}
				}
			}
		}
	}

}
