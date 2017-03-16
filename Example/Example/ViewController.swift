//
//  ViewController.swift
//  Example
//
//  Created by Artem Shimanski on 10.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import UIKit
import CloudData

let Note = Notification.Name("Note")

class A {
	var observer: NotificationObserver?
	
	init() {
		observer = NotificationCenter.default.addNotificationObserver(forName: Note, object: nil, queue: nil) { [weak self] note in
			print("\(self)")
//			print("\(note)")
		}
	}
	
	func f() {
		func ff() {
			print("\(self)")
		}
		
		DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
			print("async")
			ff()
		}
	}
	
	deinit {
		print(#function)
	}
}

class ViewController: UIViewController {

	override func viewDidLoad() {
		super.viewDidLoad()
		let a = A()
		a.f()
		NotificationCenter.default.post(name: Note, object: nil)
		DispatchQueue.main.async {
			NotificationCenter.default.post(name: Note, object: nil)
		}
	}

	override func didReceiveMemoryWarning() {
		super.didReceiveMemoryWarning()
		// Dispose of any resources that can be recreated.
	}


}

