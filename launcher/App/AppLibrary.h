#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The launcher's list of imported applications. An entry records where an
// unchanged executable lives and which folder becomes its working directory,
// so it can be started again without picking the file. Entries are data only:
// nothing here loads, patches or signs application code.
typedef NS_ENUM(NSInteger, TKAppSource) {
    // Runs in place from the app's Documents folder, next to its resources.
    TKAppSourceDocuments,
    // Tolkara's own verified copy in Documents/GuestModules (executable only).
    TKAppSourceCopy,
};

@interface TKApp : NSObject
@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly) TKAppSource source;
// Both relative to Documents. An empty working directory is Documents itself.
@property(nonatomic, readonly, copy) NSString *executable;
@property(nonatomic, readonly, copy) NSString *workingDirectory;
// SHA-256 recorded when the entry was added; empty if unknown.
@property(nonatomic, readonly, copy) NSString *sha256;
@property(nonatomic, readonly, copy, nullable) NSString *profile;
// From the profile: the command line of a compatibility runtime (its own
// arguments after the executable, and environment variables whose values may
// use `${Documents}`). Empty for an application started on its own.
@property(nonatomic, readonly, copy) NSArray<NSString *> *arguments;
@property(nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *environment;
// From the profile: the runtime's folder, relative to Documents, and the
// libraries it opens by path, relative to that folder; placed with the
// executable at start. Nil and empty for an application started on its own.
@property(nonatomic, readonly, copy, nullable) NSString *runtime;
@property(nonatomic, readonly, copy) NSArray<NSString *> *libraries;
// From the profile: megabytes of prepared executable memory the runtime writes
// its own code into; 0 for none.
@property(nonatomic, readonly) NSUInteger codePool;
@property(nonatomic, readonly) NSDate *added;
@property(nonatomic, readonly, nullable) NSDate *lastLaunched;
@end

// Thread-safe. Hashing and copying happen outside the lock, so imports and
// discovery may run on a background queue while the UI reads `apps`.
@interface TKAppLibrary : NSObject
// Validated app profiles (profiles/*/profile.json) in a directory.
+ (NSArray<NSDictionary *> *)profilesInDirectory:(NSString *)directory;
// Documents-relative executable a profile describes: `executable` under its
// `runtime` folder when it names one (a compatibility runtime started with the
// application's files as the working directory), else under `workingDirectory`.
+ (NSString *)executableOfProfile:(NSDictionary *)profile;
// `storage` holds apps.json and should not be user-visible; `documents` holds
// the applications' files and Tolkara's module copies (GuestModules).
- (instancetype)initWithDocuments:(NSString *)documents storage:(NSString *)storage
                         profiles:(NSArray<NSDictionary *> *)profiles NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Most recently launched first, then in the order they were added.
@property(nonatomic, readonly) NSArray<TKApp *> *apps;
// Set when a damaged apps.json was moved aside while loading.
@property(nonatomic, readonly, copy, nullable) NSString *loadWarning;
- (nullable TKApp *)appWithIdentifier:(NSString *)identifier;
// The app a launch without an explicit choice uses.
- (nullable TKApp *)defaultApp;

// Adds an executable. One inside Documents runs in place, so an application
// bundle keeps its resources; one elsewhere is copied into GuestModules.
// `copy` forces a copy (developer staging). Re-importing returns the existing
// entry. Slow: hashes and parses the file. Call off the main thread.
- (nullable TKApp *)importExecutable:(NSString *)path copy:(BOOL)copy error:(NSError **)error;
// Adds apps a profile describes whose files are present, and a module imported
// by an older launcher. Removed apps are not re-added. Returns new entries. Slow.
- (NSArray<TKApp *> *)discover;

- (BOOL)renameApp:(TKApp *)app to:(NSString *)name error:(NSError **)error;
// Removes the entry. Files in Documents are never touched; Tolkara's own copy
// of an executable is deleted when no other entry uses it.
- (BOOL)removeApp:(TKApp *)app error:(NSError **)error;
- (BOOL)recordLaunchOfApp:(TKApp *)app error:(NSError **)error;
// Deletes an application's files: a folder in Documents (relative, for
// example "World of Warcraft") that holds an entry's or a profile's
// executable, never Tolkara's own folders (GuestModules, GuestCompatibility,
// LocalSigning) or Documents itself. Entries whose files were inside go too;
// their profiles are added again when their files are copied back. Returns
// the names of the applications removed. For Tolkara Management on the Mac.
- (nullable NSArray<NSString *> *)removeApplicationFolder:(NSString *)folder error:(NSError **)error;

// Absolute, checked paths for starting the app. A Documents executable must be
// a regular file that stays inside Documents; a copy must match its hash.
- (nullable NSString *)executablePathForApp:(TKApp *)app error:(NSError **)error;
- (nullable NSString *)workingDirectoryForApp:(TKApp *)app error:(NSError **)error;
// SHA-256 of the executable as it is now (it may have been updated in place);
// the recorded hash follows it. Slow: hashes the file. Call off the main thread.
- (nullable NSString *)currentSHA256OfApp:(TKApp *)app error:(NSError **)error;

// The caseAliases of the app's profile, {alias: target}; empty without one.
// An alias is a path inside the working directory; its target, a name in the
// same folder differing from the alias's last component only in case.
- (NSDictionary<NSString *, NSString *> *)caseAliasesForApp:(TKApp *)app;
// iPadOS's file system is case-sensitive and macOS's default is not: links
// each missing alias to its existing target (a relative symbolic link in the
// user's copy of the app's files). Nothing outside the working directory is
// created or followed. One line per alias, for the log.
- (NSArray<NSString *> *)linkCaseAliasesForApp:(TKApp *)app;
@end

NS_ASSUME_NONNULL_END
