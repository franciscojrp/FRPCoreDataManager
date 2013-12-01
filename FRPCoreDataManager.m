//
//  FRPCoreDataManager.m
//
//  Created by Francisco José Rodríguez Pérez on 12/06/12.
//  Copyright (c) 2012. All rights reserved.
//

#import "FRPCoreDataManager.h"

#define SAVE_TO_DISK_TIME_INTERVAL 0.6
#define SQLITE_FILE_NAME @"store.sqlite"

@interface FRPCoreDataManager ()

@property (strong, nonatomic) NSManagedObjectContext *privateWriterContext; // tied to the persistent store coordinator

- (void)contextObjectsDidChange:(NSNotification *)notification;
- (void)saveToDisk:(NSNotification *)notification;

- (NSURL *)storeURL;

@end

@implementation FRPCoreDataManager

@synthesize mainObjectContext = __mainObjectContext;
@synthesize managedObjectModel = __managedObjectModel;
@synthesize persistentStoreCoordinator = __persistentStoreCoordinator;
@synthesize persistentStore = __persistentStore;

static FRPCoreDataManager *_sharedInstance;
+ (FRPCoreDataManager *)sharedInstance
{
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
                      _sharedInstance = [[FRPCoreDataManager alloc] init];
                  });
    return _sharedInstance;
}

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(saveToDisk:)
                                               object:nil];

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationWillTerminateNotification
                                                  object:nil];

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationWillResignActiveNotification
                                                  object:nil];
}

- (id)init
{
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(saveToDisk:)
                                                     name:UIApplicationWillTerminateNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(saveToDisk:)
                                                     name:UIApplicationWillResignActiveNotification
                                                   object:nil];
    }
    return self;
}

- (void)deleteAllDBContents
{
    [NSFetchedResultsController deleteCacheWithName:nil];

    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(saveToDisk:)
                                               object:nil];

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSManagedObjectContextObjectsDidChangeNotification
                                                  object:self.mainObjectContext];

    NSError *error;
    [[self persistentStoreCoordinator] removePersistentStore:[self persistentStore] error:&error];
    [[NSFileManager defaultManager] removeItemAtPath:[self persistentStore].URL.path error:&error];

    __persistentStoreCoordinator = nil;
    __mainObjectContext = nil;
}

#pragma mark - Core Data stack

- (NSManagedObjectContext *)tempInMemoryObjectContext
{
    if (!_tempInMemoryObjectContext) {
        NSMutableDictionary *options = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
                                        [NSNumber numberWithBool:YES], NSMigratePersistentStoresAutomaticallyOption,
                                        [NSNumber numberWithBool:YES], NSInferMappingModelAutomaticallyOption, nil];
        NSError *error = nil;
        NSPersistentStoreCoordinator *persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self managedObjectModel]];
        [persistentStoreCoordinator addPersistentStoreWithType:NSInMemoryStoreType
                                                 configuration:nil
                                                           URL:[NSURL URLWithString:@"tempInMemoryStore"]
                                                       options:options
                                                         error:&error];
        
        _tempInMemoryObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        [_tempInMemoryObjectContext setMergePolicy:[[NSMergePolicy alloc] initWithMergeType:NSOverwriteMergePolicyType]];
        [_tempInMemoryObjectContext setPersistentStoreCoordinator:persistentStoreCoordinator];
    }
    
    return _tempInMemoryObjectContext;
}

- (NSManagedObjectContext *)mainObjectContext
{
    if (__mainObjectContext == nil) {
        __mainObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        [__mainObjectContext setMergePolicy:[[NSMergePolicy alloc] initWithMergeType:NSOverwriteMergePolicyType]];
        [__mainObjectContext setParentContext:self.privateWriterContext];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(contextObjectsDidChange:)
                                                     name:NSManagedObjectContextObjectsDidChangeNotification
                                                   object:__mainObjectContext];
    }

    return __mainObjectContext;
}

- (NSManagedObjectContext *)concurrentObjectContext
{
    NSManagedObjectContext *concurrentObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];

    [concurrentObjectContext setMergePolicy:[[NSMergePolicy alloc] initWithMergeType:NSOverwriteMergePolicyType]];
    [concurrentObjectContext setParentContext:self.mainObjectContext];

    return concurrentObjectContext;
}

- (NSManagedObjectContext *)tempMainObjectContext
{
    NSManagedObjectContext *tempMainObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    
    [tempMainObjectContext setMergePolicy:[[NSMergePolicy alloc] initWithMergeType:NSOverwriteMergePolicyType]];
    [tempMainObjectContext setParentContext:self.mainObjectContext];
    
    return tempMainObjectContext;
}

- (NSManagedObjectModel *)managedObjectModel
{
    if (__managedObjectModel == nil) {
        __managedObjectModel = [NSManagedObjectModel mergedModelFromBundles:nil];
    }

    return __managedObjectModel;
}

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (__persistentStoreCoordinator == nil) {
        NSMutableDictionary *options = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
                                        [NSNumber numberWithBool:YES], NSMigratePersistentStoresAutomaticallyOption,
                                        [NSNumber numberWithBool:YES], NSInferMappingModelAutomaticallyOption, nil];
        NSError *error = nil;
        __persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self managedObjectModel]];
        __persistentStore = [__persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                       configuration:nil
                                                                                 URL:[self storeURL]
                                                                             options:options
                                                                               error:&error];
        if (!__persistentStore) {
            NSLog(@"Unresolved error %@, %@", error, [error userInfo]);

            [[NSFileManager defaultManager] removeItemAtPath:[self storeURL].path error:&error];

            __persistentStore = [__persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                           configuration:nil
                                                                                     URL:[self storeURL]
                                                                                 options:options
                                                                                   error:&error];
        }
    }

    return __persistentStoreCoordinator;
}

- (NSManagedObjectContext *)createNewManagedObjectContext
{
    NSManagedObjectContext *retValue = nil;
    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];

    if (coordinator != nil) {
        retValue = [[NSManagedObjectContext alloc] init];
        [retValue setPersistentStoreCoordinator:coordinator];
    }
    return retValue;
}

#pragma mark - Private methods

- (NSManagedObjectContext *)privateWriterContext
{
    if (_privateWriterContext == nil) {
        _privateWriterContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        [_privateWriterContext setMergePolicy:[[NSMergePolicy alloc] initWithMergeType:NSOverwriteMergePolicyType]];
        NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
        [_privateWriterContext performBlockAndWait:^{
             [_privateWriterContext setPersistentStoreCoordinator:coordinator];
         }];
    }

    return _privateWriterContext;
}

- (void)contextObjectsDidChange:(NSNotification *)notification
{
    if (notification.object == self.mainObjectContext) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveToDisk:) object:nil];

        [self performSelector:@selector(saveToDisk:) withObject:nil afterDelay:SAVE_TO_DISK_TIME_INTERVAL];
    }
}

- (void)saveToDisk:(NSNotification *)notification
{
    NSManagedObjectContext *savingContext = self.mainObjectContext;

    NSError *error = nil;
    BOOL success = [self.mainObjectContext save:&error];
    if (success) {
        NSLog(@"Main context saved");
    } else {
        NSLog(@"ERROR saving main context: %@", [error localizedDescription]);
    }
    
    if (![savingContext.parentContext hasChanges]) {
        return;
    }

    void (^saveToDiskBlock)() = ^{
        [savingContext.parentContext performBlock:^{
             NSError *error = nil;
             BOOL success = [savingContext.parentContext save:&error];
             if (success) {
                 NSLog (@"Writer context saved to disk");
             } else {
                 NSLog (@"ERROR saving writer context: %@", [error localizedDescription]);
             }
         }];
    };

    if (notification) {
        [savingContext performBlockAndWait:saveToDiskBlock];
    } else {
        [savingContext performBlock:saveToDiskBlock];
    }
}

- (NSURL *)storeURL
{
    return [[[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject] URLByAppendingPathComponent:SQLITE_FILE_NAME];
}

@end
