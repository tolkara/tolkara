#pragma once
#import <Foundation/Foundation.h>
#import "HostExecutionProbe.h"

NS_ASSUME_NONNULL_BEGIN

// Development checks shared by the Diagnostics menu and the launch arguments
// used by tools/. Each returns the text the launcher shows and writes the same
// report file under Documents that the launch-argument form always wrote.
// None of them runs application code.

NSString *TKDocumentsPath(NSString *name);
// Before a launch replaces Documents/native-guest.log: the last three runs'
// logs stay beside it as native-guest.1.log (the latest) to native-guest.3.log,
// so a run that ended in a crash can still be read after the next start.
void TKKeepEarlierLogs(void);

// Main thread. Process and memory facts (debugger, code signing, footprint,
// arena limit); no probe sample runs and no code is executed.
NSString *TKHostDiagnosticsReport(void);
// Background queue. Emulated-memory self-test, then loads `executable` (if
// given) into guest memory without running it. `missing` explains a nil path.
NSString *TKLoaderCheck(NSString *_Nullable executable, NSString *_Nullable missing);
// Background queue. Runs our own test program through the CPU interpreter.
NSString *TKCPUProbeReport(void);
// Background queue. Compiles our own shader fixtures in Documents/LocalShaderProbe.
NSString *TKLocalShaderProbeReport(void);
// Background queue. Loads every shader library the runtime captured in
// Documents/ShaderRequests on this device's own Metal; reads them only.
// A --probe-run-id= launch argument tags the report.
NSString *TKCapturedShaderProbeReport(void);
// Main thread. Maps our own signed pages; no debugger, JIT or app code.
NSString *TKSignedCacheProbeReport(void);
// Main thread, from a run-loop timer callout: pumps the run loop while waiting.
// Loads the Metal compatibility library, so restart before starting an app.
NSString *TKShaderPauseProbeReport(void);
// Background queue. Experimental development probe (--vm-probe): how much
// virtual memory iPadOS lets this app reserve, singly and in total, anonymous,
// PROT_NONE, at fixed addresses and file-backed. Reserves and releases only
// its own address space; a fixed address already in use is reported, never
// replaced. Writes Documents/vm-probe.txt.
NSString *TKVMProbeReport(void);
// Background queue. Only our signed scalar/SIMD fixture accesses software VAs.
NSString *TKSparseMemoryProbeReport(void);
// Main thread. Executes our own two-instruction sample; a code-signing
// rejection can terminate the process. Launch arguments tag the report.
NSString *TKExecutionProbeReport(HPMode mode, NSArray<NSString *> *arguments);

NS_ASSUME_NONNULL_END
