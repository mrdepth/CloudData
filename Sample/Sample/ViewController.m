//
//  ViewController.m
//  Sample
//
//  Created by Artem Shimanski on 09.11.16.
//  Copyright © 2016 Artem Shimanski. All rights reserved.
//

#import "ViewController.h"
#import "Parent+CoreDataClass.h"
#import "Child+CoreDataClass.h"
@import CoreData;
@import CloudData;

@interface ViewController ()<NSFetchedResultsControllerDelegate>
@property (nonatomic, strong) NSPersistentStoreCoordinator* persistentStoreCoordinator;
@property (nonatomic, strong) NSManagedObjectModel* managedObjectModel;
@property (nonatomic, strong) NSManagedObjectContext* managedObjectContext;
@property (nonatomic, strong) NSFetchedResultsController* results;

@end

@implementation ViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:[[NSBundle mainBundle] URLForResource:@"Sample" withExtension:@"momd"]];
	self.persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.managedObjectModel];
	NSString* path = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"test.sqlite"];
//	[[NSFileManager defaultManager] removeItemAtPath:path error:nil];
	NSError* error;
	[self.persistentStoreCoordinator addPersistentStoreWithType:CDCloudStoreType configuration:nil URL:[NSURL fileURLWithPath:path] options:@{CDCloudStoreOptionMergePolicyType:@(NSMergeByPropertyObjectTrumpMergePolicyType)} error:&error];

//	[[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
//	[self.persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:path] options:nil error:&error];
	
	self.managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
	self.managedObjectContext.persistentStoreCoordinator = self.persistentStoreCoordinator;
	
	NSFetchRequest* request = [NSFetchRequest fetchRequestWithEntityName:@"Parent"];
	request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]];
	self.results = [[NSFetchedResultsController alloc] initWithFetchRequest:request managedObjectContext:self.managedObjectContext sectionNameKeyPath:@"name" cacheName:nil];
	self.results.delegate = self;
	[self.results performFetch:nil];
	
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didSave:) name:NSManagedObjectContextDidSaveNotification object:nil];
	/*
	NSManagedObjectContext* other = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
	other.persistentStoreCoordinator = self.persistentStoreCoordinator;
	
	Parent* parent = [NSEntityDescription insertNewObjectForEntityForName:@"Parent" inManagedObjectContext:self.managedObjectContext];
	parent.children = [NSSet setWithObject:[NSEntityDescription insertNewObjectForEntityForName:@"Child" inManagedObjectContext:self.managedObjectContext]];
	[self.managedObjectContext save:nil];
	
	Parent* parent2 = [other objectWithID:parent.objectID];
	parent.children = [NSSet setWithObject:[NSEntityDescription insertNewObjectForEntityForName:@"Child" inManagedObjectContext:self.managedObjectContext]];
	parent2.children = [NSSet setWithObject:[NSEntityDescription insertNewObjectForEntityForName:@"Child" inManagedObjectContext:parent2.managedObjectContext]];
	[self.managedObjectContext save:nil];
	
	error = nil;
	[other save:&error];//NSManagedObjectMergeError
	for (NSMergeConflict* conflict in error.userInfo[@"conflictList"])
		NSLog(@"%@", conflict);
	NSMergeConflict* conflict = error.userInfo[@"conflictList"][0];
	NSMergePolicy* policy = NSMergeByPropertyObjectTrumpMergePolicy;
	BOOL b = [policy resolveConflicts:error.userInfo[@"conflictList"] error:&error];
	error = nil;
	[other save:&error];
	[self.managedObjectContext refreshAllObjects];
	[other refreshAllObjects];
	NSLog(@"%@", [parent.children allObjects]);
	NSLog(@"%@", [parent2.children allObjects]);*/
}


- (void)didReceiveMemoryWarning {
	[super didReceiveMemoryWarning];
	// Dispose of any resources that can be recreated.
}

- (IBAction)onAdd:(id)sender {
	Parent* parent = [NSEntityDescription insertNewObjectForEntityForName:@"Parent" inManagedObjectContext:self.managedObjectContext];
	Child* child = [NSEntityDescription insertNewObjectForEntityForName:@"Child" inManagedObjectContext:self.managedObjectContext];
	child.parent = parent;
	parent.name = [NSUUID UUID].UUIDString;
	child.name = [NSUUID UUID].UUIDString;
	child.number = rand();
	[self.managedObjectContext save:nil];
}


- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
	return self.results.sections.count;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return [self.results.sections[section] numberOfObjects];
}

- (UITableViewCell*) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
	Parent* object = [self.results objectAtIndexPath:indexPath];
	Child* child = [object.children anyObject];
	cell.textLabel.text = object.name;
	cell.detailTextLabel.text = child.name;
	return cell;
}

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	Parent* object = [self.results objectAtIndexPath:indexPath];
	object.name = [NSUUID UUID].UUIDString;
	[self.managedObjectContext save:nil];
}

- (UITableViewCellEditingStyle) tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
	return UITableViewCellEditingStyleDelete;
}

- (void) tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
	Parent* object = [self.results objectAtIndexPath:indexPath];
	[self.managedObjectContext deleteObject:object];
	[self.managedObjectContext save:nil];
}

#pragma makr - NSFetchedResultsControllerDelegate

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller {
	
}

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller {
	[self.tableView reloadData];
}

- (void) didSave:(NSNotification*) note {
	NSManagedObjectContext* other = note.object;
	if (other != self.managedObjectContext && other.persistentStoreCoordinator == self.managedObjectContext.persistentStoreCoordinator) {
		[self.managedObjectContext performBlock:^{
			[self.managedObjectContext mergeChangesFromContextDidSaveNotification:note];
		}];
	}
}
@end
