##FRPCoreDataManager

Base Core Data manager for typical Core Data based iOS apps

The idea behind this manager is having a multi context core data base for an app that shows data to the user fetched directly from the database and does background syncing of data.

The manager manages three core data contexts:
* __Main context__: the context tight to the main thread and that should be used for every operation related to data from the UI. Every change made to an object from this context is automatically saved.
* __Concurrent context__: instead of a permanent context, this property returns a fresh object context each time. The context is a child of the main object context and, every time you save its changes, those changes are propagated to the main object context.
* __Private writer context__: this is a private context that is the father of the main object context. This context is the one associated with the persistent store coordinator and thus the one that actually writes the changes to disk. The saving is managed automatically and it is triggered whenever a change is made in the main object context and no other change is detected in the next 0.6 secs.

It also provides a temporary in memory object context tied to the main thread that can be used to temoporary hold data you are going to discard but want to show to the user in the UI.

###Usage

Just add the files to your project. The manager will load (and if there are more than one merge) the model files in your project.
Then in your code just use the manager shared instance to access its funcionality: `[FRPCoreDataManager sharedInstance].mainObjectContext`
