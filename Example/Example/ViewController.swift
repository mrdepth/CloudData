//
//  ViewController.swift
//  Example
//
//  Created by Artem Shimanski on 10.03.17.
//  Copyright © 2017 Artem Shimanski. All rights reserved.
//

import UIKit
import CloudData
import CoreData

class ViewController: UITableViewController, NSFetchedResultsControllerDelegate {
	
	lazy var managedObjectModel = NSManagedObjectModel(contentsOf: Bundle.main.url(forResource: "Example", withExtension: "momd")!)!
	
	lazy var coordinator: NSPersistentStoreCoordinator = {
		let url = URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first!).appendingPathComponent("example.sqlie")
//		try? FileManager.default.removeItem(at: url)
		let coordinator = NSPersistentStoreCoordinator(managedObjectModel: self.managedObjectModel)
		
		try! coordinator.addPersistentStore(ofType: CloudStoreType, configurationName: nil, at: url, options: nil)
		return coordinator
	}()
	
	lazy var managedObjectContext: NSManagedObjectContext = {
		let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
		context.persistentStoreCoordinator = self.coordinator
		return context
	}()

	override func viewDidLoad() {
		super.viewDidLoad()
		
		/*for _ in 0..<10 {
			var context: NSManagedObjectContext? = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
			context?.persistentStoreCoordinator = coordinator
			context?.perform {
				for _ in 0..<1000 {
					let parent = try? context?.fetch(NSFetchRequest<Parent>(entityName: "Parent")).first ?? {
						let parent = Parent(context: context!)
						parent.name = UUID().uuidString
						return parent
					}()
					let child = Child(context: context!)
					child.name = UUID().uuidString
					child.parent = parent
				}
				try? context?.save()
				print("save")
				context = nil

			}
		}*/
		
		
		let request = NSFetchRequest<Parent>(entityName: "Parent")
		request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
		result = NSFetchedResultsController(fetchRequest: request, managedObjectContext: managedObjectContext, sectionNameKeyPath: nil, cacheName: nil)
		result?.delegate = self
		try? result?.performFetch()
		
		NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: .main) { [weak self] (note) in
			guard let strongSelf = self else {return}
			guard let other = note.object as? NSManagedObjectContext else {return}
			if other.persistentStoreCoordinator == strongSelf.managedObjectContext.persistentStoreCoordinator {
				strongSelf.managedObjectContext.mergeChanges(fromContextDidSave: note)
			}
		}
	}
	
	override func didReceiveMemoryWarning() {
		super.didReceiveMemoryWarning()
		// Dispose of any resources that can be recreated.
	}
	
	@IBAction func onAdd(_ sender: Any) {
		let parent = Parent(context: managedObjectContext)
		parent.name = UUID().uuidString
		var child = Child(context: managedObjectContext)
		child.parent = parent
		child.name = "Child 1"
		
		child = Child(context: managedObjectContext)
		child.parent = parent
		child.name = "Child 2"

		try? managedObjectContext.save()
	}
	
	var result: NSFetchedResultsController<Parent>?
	
	override func numberOfSections(in tableView: UITableView) -> Int {
		return result?.sections?.count ?? 0
	}
	
	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		return result?.sections?[section].numberOfObjects ?? 0
	}
	
	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
		let parent = result?.object(at: indexPath)
		let child = parent?.children?.firstObject as? Child
		
		cell.textLabel?.text = parent?.name
		cell.detailTextLabel?.text = child?.name
		return cell
	}
	
	override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCellEditingStyle {
		return .delete
	}

	
	override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCellEditingStyle, forRowAt indexPath: IndexPath) {
		let parent = result?.object(at: indexPath)
		parent?.managedObjectContext?.delete(parent!)
		try? parent?.managedObjectContext?.save()
	}
	func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
		tableView.reloadData()
	}

}

