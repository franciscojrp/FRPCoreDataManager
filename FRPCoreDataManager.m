//
//  FRPCoreDataManager.m
//
//  Created by Francisco Rodríguez on 11/12/13.
//  Copyright (c) 2013 Francisco Rodríguez. All rights reserved.
//

#import "FRPCoreDataManager.h"

#define SAVE_TO_DISK_TIME_INTERVAL 0.3
#define SQLITE_FILE_NAME @"store.sqlite"

@interface FRPCoreDataManager ()

@property (strong, nonatomic) NSManagedObjectContext *privateWriterContext; // managedObjectContext tied to the persistent store coordinator

- (void)contextObjectsDidChange:(NSNotification *)notification;
- (void)contextWillSave:(NSNotification *)notification;
- (void)contextDidSave:(NSNotification *)notification;
- (void)saveToDisk:(NSNotification *)notification;

- (NSURL *)storeURL;

@end

@implementation FRPCoreDataManager

@synthesize mainObjectContext = __mainObjectContext;
@synthesize concurrentObjectContext = __concurrentObjectContext;
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
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSManagedObjectContextWillSaveNotification
                                                  object:self.mainObjectContext];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSManagedObjectContextDidSaveNotification
                                                  object:self.mainObjectContext];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSManagedObjectContextWillSaveNotification
                                                  object:self.concurrentObjectContext];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSManagedObjectContextDidSaveNotification
                                                  object:self.concurrentObjectContext];

    NSError *error;
    [[self persistentStoreCoordinator] removePersistentStore:[self persistentStore] error:&error];
    [[NSFileManager defaultManager] removeItemAtPath:[self persistentStore].URL.path error:&error];

    __persistentStoreCoordinator = nil;
    __mainObjectContext = nil;
    __concurrentObjectContext = nil;
}

+ (void)saveContext:(NSManagedObjectContext *)context
{
    [context performBlock:^{
        if (context.hasChanges) {
            NSError *error = nil;
            BOOL success = [context save:&error];
            if (success) {
                CLS_LOG(@"Context saved");
            } else {
                CLS_LOG(@"ERROR saving context: %@", error);
            }

            if (context.parentContext) {
                [self saveContext:context.parentContext];
            }
        }
    }];
}

#pragma mark - Core Data stack

- (NSManagedObjectContext *)tempInMemoryObjectContext
{
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

    NSManagedObjectContext *tempInMemoryObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    [tempInMemoryObjectContext setMergePolicy:[[NSMergePolicy alloc] initWithMergeType:NSOverwriteMergePolicyType]];
    [tempInMemoryObjectContext setPersistentStoreCoordinator:persistentStoreCoordinator];

    return tempInMemoryObjectContext;
}

- (NSManagedObjectContext *)mainObjectContext
{
    if (__mainObjectContext == nil) {
        void(^createMainObjContext)(void) = ^{
            __mainObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
            [__mainObjectContext setMergePolicy:[[NSMergePolicy alloc] initWithMergeType:NSOverwriteMergePolicyType]];
            [__mainObjectContext setParentContext:self.privateWriterContext];
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(contextObjectsDidChange:)
                                                         name:NSManagedObjectContextObjectsDidChangeNotification
                                                       object:__mainObjectContext];
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(contextWillSave:)
                                                         name:NSManagedObjectContextWillSaveNotification
                                                       object:__mainObjectContext];
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(contextDidSave:)
                                                         name:NSManagedObjectContextDidSaveNotification
                                                       object:__mainObjectContext];
        };
        if (NSThread.isMainThread) {
            createMainObjContext();
        } else {
            dispatch_sync(dispatch_get_main_queue(), createMainObjContext);
        }
    }

    return __mainObjectContext;
}

- (NSManagedObjectContext *)concurrentObjectContext
{
    if (__concurrentObjectContext == nil) {
        __concurrentObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];

        [__concurrentObjectContext setMergePolicy:[[NSMergePolicy alloc] initWithMergeType:NSOverwriteMergePolicyType]];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(contextWillSave:)
                                                     name:NSManagedObjectContextWillSaveNotification
                                                   object:__concurrentObjectContext];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(contextDidSave:)
                                                     name:NSManagedObjectContextDidSaveNotification
                                                   object:__concurrentObjectContext];
        NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
        [__concurrentObjectContext performBlockAndWait:^{
            [__concurrentObjectContext setPersistentStoreCoordinator:coordinator];
        }];
    }

    return __concurrentObjectContext;
}

- (NSManagedObjectContext *)concurrentObjectContextFromContext:(NSManagedObjectContext *)context
{
    NSManagedObjectContext *concurrentObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];

    [concurrentObjectContext setMergePolicy:[[NSMergePolicy alloc] initWithMergeType:NSOverwriteMergePolicyType]];
    [concurrentObjectContext setParentContext:context];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(contextWillSave:)
                                                 name:NSManagedObjectContextWillSaveNotification
                                               object:concurrentObjectContext];

    return concurrentObjectContext;
}

- (NSManagedObjectContext *)tempMainObjectContext
{
    NSManagedObjectContext *tempMainObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    
    [tempMainObjectContext setMergePolicy:[[NSMergePolicy alloc] initWithMergeType:NSOverwriteMergePolicyType]];
    [tempMainObjectContext setParentContext:self.mainObjectContext];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(contextWillSave:)
                                                 name:NSManagedObjectContextWillSaveNotification
                                               object:tempMainObjectContext];

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
            CLS_LOG(@"Unresolved error %@, %@", error, [error userInfo]);

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
    NSManagedObjectContext *ctx = (NSManagedObjectContext *)notification.object;
    if (ctx.insertedObjects.count > 0) {
        NSError *error = nil;
        [ctx obtainPermanentIDsForObjects:ctx.insertedObjects.allObjects error:&error];
        if (error) {
            CLS_LOG(@"contextObjectsDidChange: ERROR obtaining permanent ids for %@", ctx.insertedObjects);
        }
    }

    if (ctx == self.mainObjectContext) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveToDisk:) object:nil];

        [self performSelector:@selector(saveToDisk:) withObject:nil afterDelay:SAVE_TO_DISK_TIME_INTERVAL];
    }
}

- (void)contextWillSave:(NSNotification *)notification
{
    NSManagedObjectContext *ctx = (NSManagedObjectContext *)notification.object;
    NSError *error = nil;
    [ctx obtainPermanentIDsForObjects:ctx.insertedObjects.allObjects error:&error];
    if (error) {
        CLS_LOG(@"contextWillSave: ERROR obtaining permanent ids for %@", ctx.insertedObjects);
    }
}

- (void)contextDidSave:(NSNotification *)notification
{
    NSManagedObjectContext *ctx = (NSManagedObjectContext *)notification.object;
    if ([ctx isEqual:self.mainObjectContext]) {
        [self.concurrentObjectContext performBlock:^{
            [self.concurrentObjectContext mergeChangesFromContextDidSaveNotification:notification];
        }];
    } else {
        [self.privateWriterContext performBlock:^{
            [self.privateWriterContext mergeChangesFromContextDidSaveNotification:notification];
            [self.mainObjectContext performBlock:^{
                CLS_LOG(@"Merging changes from concurrent context into main context");
                [self.mainObjectContext mergeChangesFromContextDidSaveNotification:notification];
            }];
        }];
    }
}

- (void)saveToDisk:(NSNotification *)notification
{
    NSManagedObjectContext *savingContext = self.mainObjectContext;

    NSError *error = nil;
    BOOL success = [self.mainObjectContext save:&error];
    if (success) {
        CLS_LOG(@"Main context saved");
    } else {
        CLS_LOG(@"ERROR saving main context: %@", error);
    }

    void (^saveToDiskBlock)() = ^{
        [savingContext.parentContext performBlock:^{
            if (![savingContext.parentContext hasChanges]) {
                return;
            }
            NSError *error = nil;
            BOOL success = [savingContext.parentContext save:&error];
            if (success) {
                CLS_LOG (@"Writer context saved to disk");
            } else {
                CLS_LOG (@"ERROR saving writer context: %@", error);
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

