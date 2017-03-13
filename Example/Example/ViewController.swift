//
//  ViewController.swift
//  Example
//
//  Created by Artem Shimanski on 10.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import UIKit

class A {
	lazy var v: Int = {
		assert(false)
		return 10
	}()
	
	func log() throws {
		print("\(self.v)")
	}
}

class ViewController: UIViewController {

	override func viewDidLoad() {
		super.viewDidLoad()
		let a = A()
		try? a.log()
		// Do any additional setup after loading the view, typically from a nib.
	}

	override func didReceiveMemoryWarning() {
		super.didReceiveMemoryWarning()
		// Dispose of any resources that can be recreated.
	}


}

