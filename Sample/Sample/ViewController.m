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
#import <objc/runtime.h>
@import CoreData;
@import CloudData;
@import CloudKit;

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
	[self.persistentStoreCoordinator addPersistentStoreWithType:CDCloudStoreType configuration:nil URL:[NSURL fileURLWithPath:path] options:@{CDCloudStoreOptionMergePolicyType:@(NSMergeByPropertyStoreTrumpMergePolicyType)} error:&error];

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
	
	/*//return;
	NSManagedObjectContext* other = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
	other.persistentStoreCoordinator = self.persistentStoreCoordinator;
	Parent* parent;
	//Parent* parent = [NSEntityDescription insertNewObjectForEntityForName:@"Parent" inManagedObjectContext:self.managedObjectContext];
	//parent = [[self.managedObjectContext executeFetchRequest:[Parent fetchRequest] error:nil] lastObject];
	NSManagedObjectID* objectID = [self.persistentStoreCoordinator managedObjectIDForURIRepresentation:[NSURL URLWithString:@"x-coredata://32EE7420-95B3-418C-B665-0A6FF68AE2AF/Parent/pidC3291DEB-3EFA-4238-BA15-6E37D9AA53F0"]];
	objc_setAssociatedObject(self.managedObjectContext, @"_test", @"123", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	parent = [self.managedObjectContext existingObjectWithID:objectID error:nil];
	if (!parent) {
		parent = [NSEntityDescription insertNewObjectForEntityForName:@"Parent" inManagedObjectContext:self.managedObjectContext];
		parent.name = @"before";
	}
	else
		parent.name = @"after";

	//parent.name = @"original";
	//Child* child = [NSEntityDescription insertNewObjectForEntityForName:@"Child" inManagedObjectContext:self.managedObjectContext];
	[self.managedObjectContext save:&error];
	return;
	
	Parent* parent2 = [other objectWithID:parent.objectID];
	//parent.name = @"name 1";
	parent2.name = @"name 2";
	[self.managedObjectContext save:nil];
	
	error = nil;
	//[other save:&error];//NSManagedObjectMergeError
	error = [NSError errorWithDomain:@"" code:0 userInfo:@{@"conflictList":@[[[NSMergeConflict alloc] initWithSource:parent2 newVersion:2 oldVersion:1 cachedSnapshot:@{@"name":@"original"} persistedSnapshot:nil]]}];
	for (NSMergeConflict* conflict in error.userInfo[@"conflictList"])
		NSLog(@"%@", conflict);
	NSMergeConflict* conflict = error.userInfo[@"conflictList"][0];
	NSMergePolicy* policy = NSMergeByPropertyStoreTrumpMergePolicy;
	BOOL b = [policy resolveConflicts:error.userInfo[@"conflictList"] error:&error];
	error = nil;
	[other save:&error];
	[self.managedObjectContext refreshAllObjects];
	[other refreshAllObjects];*/
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
