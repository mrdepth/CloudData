//
//  Reachability.swift
//  CoudData
//
//  Created by Artem Shimanski on 10.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import Foundation
import SystemConfiguration
import Darwin

enum NetworkStatus {
	case notReachable
	case reachableViaWiFi
	case reachableViaWWAN

}

extension Notification.Name {
	static let ReachabilityChanged = Notification.Name(rawValue: "ReachabilityChanged")
}

class Reachability {
	private let reachability: SCNetworkReachability
	
	convenience init?() {
		var addr = sockaddr_in()
		addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
		addr.sin_family = sa_family_t(AF_INET)
		let ptr = withUnsafePointer(to: &addr) {$0.withMemoryRebound(to: sockaddr.self, capacity: 1){$0}}
		self.init(address: ptr)
	}
	
	init?(hostName: String) {
		if let reachability = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, hostName) {
			self.reachability = reachability
		}
		else {
			return nil
		}
	}
	
	init?(address: UnsafePointer<sockaddr>) {
		if let reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, address) {
			self.reachability = reachability
		}
		else {
			return nil
		}
	}
	
	deinit {
		stopNotifier()
	}
	
	func startNotifier() -> Bool {
		
		var context = SCNetworkReachabilityContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
		if (SCNetworkReachabilitySetCallback(reachability, {(reachability, flags, info) in
				guard let info = info else {return}
				let myself = Unmanaged<Reachability>.fromOpaque(info).takeUnretainedValue()
				NotificationCenter.default.post(name: .ReachabilityChanged, object: myself)
		}, &context)) {
			return SCNetworkReachabilityScheduleWithRunLoop(reachability, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
		}
		return false
	}
	
	func stopNotifier() {
		SCNetworkReachabilityUnscheduleFromRunLoop(reachability, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
	}
	
	var reachabilityStatus: NetworkStatus {
		var flags: SCNetworkReachabilityFlags = []
		SCNetworkReachabilityGetFlags(reachability, &flags)
		
		if !flags.contains(.reachable) {
			return .notReachable
		}
		else {
			var status: NetworkStatus = .notReachable
			
			if !flags.contains(.connectionRequired) {
				status = .reachableViaWiFi
			}
			
			if flags.contains(.connectionOnDemand) || flags.contains(.connectionOnTraffic) {
				if !flags.contains(.interventionRequired) {
					status = .reachableViaWiFi
				}
			}
			
			if flags.contains(.isWWAN) {
				status = .reachableViaWWAN
			}
			
			return status
		}
	}
	
	var connectionRequired: Bool {
		var flags: SCNetworkReachabilityFlags = []
		SCNetworkReachabilityGetFlags(reachability, &flags)
		return flags.contains(.connectionRequired)
	}

}
