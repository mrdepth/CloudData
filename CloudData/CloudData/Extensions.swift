//
//  Extensions.swift
//  CloudData
//
//  Created by Artem Shimanski on 13.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import Foundation
import CoreData

extension UUID {
	init(ubiquityIdentityToken token: NSCoding) {
		let data = NSKeyedArchiver.archivedData(withRootObject: token) as NSData
		let md5 = data.md5
		
		let uuid = md5.withUnsafeBytes { b -> uuid_t in
			uuid_t(b[0], b[1], b[2], b[3],
			       b[4], b[5], b[6], b[7],
			       b[8], b[9], b[10], b[11],
			       b[12], b[13], b[14], b[15])
		}
		
		self = UUID(uuid: uuid)
	}
}


extension NSAttributeDescription {
	
}

extension NSRelationshipDescription {
	
}

extension NSManagedObject {
	
}
