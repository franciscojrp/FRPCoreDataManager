//
//  FRPCoreDataManager.h
//
//  Created by Francisco José Rodríguez Pérez on 12/06/12.
//  Copyright (c) 2012. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

#define CONTEXT_FROM_CONTEXTORNIL(contextOrNil) contextOrNil == nil ? [FRPCoreDataManager sharedInstance].mainObjectContext : contextOrNil

@interface FRPCoreDataManager : NSObject

@property (nonatomic, strong, readonly) NSManagedObjectContext *tempInMemoryObjectContext;

@property (nonatomic, strong, readonly) NSManagedObjectContext *mainObjectContext;
@property (nonatomic, strong, readonly) NSManagedObjectContext *concurrentObjectContext;
@property (nonatomic, strong, readonly) NSManagedObjectContext *tempMainObjectContext;
@property (nonatomic, strong, readonly) NSManagedObjectModel *managedObjectModel;
@property (nonatomic, strong, readonly) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@property (nonatomic, strong, readonly) NSPersistentStore *persistentStore;

- (NSManagedObjectContext *)concurrentObjectContextFromContext:(NSManagedObjectContext *)context;
- (NSManagedObjectContext *)createNewManagedObjectContext;
- (void)deleteAllDBContents;

+ (void)saveContext:(NSManagedObjectContext *)context;

+ (ARKCoreDataManager *)sharedInstance;

@end
