#pragma once
#import <Foundation/Foundation.h>
#include <stdio.h>

NS_ASSUME_NONNULL_BEGIN

// Host-side view of the iPad's GameController framework, for diagnosing gamepad
// input in apps that run inside Tolkara. The framework is process-wide, so what
// this process sees is exactly what a guest's controller code can see.
//
// The interactive form (the Diagnostics menu's "Controller input" check)
// watches the framework for ten seconds: it prints what is connected, keeps
// watching for connect/disconnect events and for the controller list to fill
// in (a controller paired before the app launched can be missing from
// +controllers until it reconnects), asks the framework to look for wireless
// controllers, and listens to the input handlers, so pressing a button on a
// paired pad visibly reaches the app. It reports to Documents/controller-probe.txt.
NSString *TKControllerProbeReport(void);

// The startup form, for a native game run with --trace-controllers or the
// Documents/trace-controllers marker: one line per controller the framework
// delivers, a list count when it changes, then every connect/disconnect
// notification, every call the guest makes into GCController's class methods
// (which is how a game asks for controllers) and every setter a gamepad
// backend uses to start listening. Nothing is registered on the controllers
// themselves, so the guest's own handlers are never touched.
void TKControllerProbeStartLogging(FILE *log);

NS_ASSUME_NONNULL_END
