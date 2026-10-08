// Tolkara's execution modes, the user's persisted choice and how one
// launch resolves it. Foundation only, so it is unit-testable on the Mac.
#pragma once
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, TKExecutionMode) { TKExecutionModeNone, TKExecutionModeDeveloperService, TKExecutionModeLocalSigning,
    TKExecutionModeExternalJIT };

// Stable identifiers "developer-service" / "local-signing" / "external-jit" (TOLKARA_MODE,
// --execution-mode=<id>, the saved choice). nil for None; unknown -> None.
NSString *TKExecutionModeIdentifier(TKExecutionMode mode);
TKExecutionMode TKExecutionModeFromIdentifier(NSString *identifier);
// "Developer service" / "Local signing" / "External JIT", and a two-sentence summary: what the
// mode needs, and what it does with the application's code. nil for None.
NSString *TKExecutionModeName(TKExecutionMode mode);
NSString *TKExecutionModeSummary(TKExecutionMode mode);
// Developer service is built only into the Tolkara target
// (TOLKARA_INTEGRATED_AUTH). When unavailable, *reason explains it for the UI.
// External JIT is built only into TolkaraDiagnostics.
BOOL TKExecutionModeAvailable(TKExecutionMode mode, NSString **reason);

extern NSString *const TKExecutionModeDefaultsKey;       // "TolkaraExecutionMode": the saved identifier
extern NSString *const TKExecutionModePreselectionKey;   // Info.plist "TolkaraPreselectedExecutionMode" (TOLKARA_MODE)
extern NSString *const TKExecutionModeArgumentPrefix;    // "--execution-mode=": one launch only, never saved
TKExecutionMode TKExecutionModeLoad(NSUserDefaults *defaults);
void TKExecutionModeSave(NSUserDefaults *defaults, TKExecutionMode mode);  // None forgets the choice
extern NSString *const TKExecutionModeSaveArgument;  // "--save-execution-mode"
// Explicit setup only: persist exactly one valid, available --execution-mode.
// Without the save flag this does nothing; rejected requests leave the choice intact.
BOOL TKExecutionModeApplySaveArgument(NSArray<NSString *> *arguments, NSUserDefaults *defaults, NSString **reason);

// Where a resolved mode came from. A rejected --execution-mode value or
// preselection resolves to None with a source that starts with one of the two
// "invalid" prefixes and says why; it never falls back to another mode.
extern NSString *const TKExecutionModeSourceArgument;              // "argument"
extern NSString *const TKExecutionModeSourceSaved;                 // "saved"
extern NSString *const TKExecutionModeSourcePreselected;           // "TOLKARA_MODE"
extern NSString *const TKExecutionModeSourceNone;                  // "none": the app must ask
extern NSString *const TKExecutionModeSourceInvalidArgument;       // "invalid --execution-mode"
extern NSString *const TKExecutionModeSourceInvalidPreselection;   // "invalid TOLKARA_MODE"
BOOL TKExecutionModeSourceIsInvalid(NSString *source);
// --execution-mode=<id> > saved choice > build-time preselection > None. A
// valid preselection is saved as the user's choice when nothing is saved yet.
// No silent default. Sources never contain paths. source may be NULL.
TKExecutionMode TKExecutionModeResolve(NSArray<NSString *> *arguments, NSUserDefaults *defaults, NSString *preselected, NSString **source);

// Local signing's page container under the app home, and its display form
// "Documents/LocalSigning/page-container.dylib".
NSString *TKLocalSigningContainerPath(NSString *home);
NSString *TKLocalSigningContainerDisplayPath(void);
// One application's own container, named after the SHA-256 of its executable
// file: "Documents/LocalSigning/<sha256>.dylib" (tools/install.sh names it so).
// nil unless sha256 is 64 lowercase hex digits.
NSString *TKLocalSigningAppContainerDisplayPath(NSString *sha256);
NSString *TKLocalSigningAppContainerPath(NSString *home, NSString *sha256);
// The container to try for that executable: its own if it exists, else the
// single-application page-container.dylib if it exists, else nil. The runtime
// still refuses a container that does not belong to the executable.
NSString *TKLocalSigningFindContainer(NSString *home, NSString *sha256);

// --signed-image=<container>: exactly one non-empty value, relative values
// resolved against home, no '..' component, and the standardized path must
// stay inside home. Returns the absolute path, or nil: with *reason when the
// argument was rejected, without one when it is absent. reason may be NULL.
NSString *TKSignedImagePath(NSArray<NSString *> *arguments, NSString *home, NSString **reason);
// "~" or "~/..." for a path inside home; only the last component otherwise, so
// logs never carry an absolute path.
NSString *TKHomeDisplayPath(NSString *path, NSString *home);
