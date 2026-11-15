#pragma once
#import <Foundation/Foundation.h>
#include <stdio.h>

NS_ASSUME_NONNULL_BEGIN

// Host-side view of the iPad's GameController framework, for diagnosing gamepad
// input in apps that run inside Tolkara. The framework is process-wide, so what
// this process sees is what a guest's controller code can see.

// The Diagnostics menu's "Controller input" check. Main thread; returns at
// once and reports on the main queue: a first text while it watches, then the
// result with finished=YES after `seconds`. It prints what is connected, keeps
// watching for connect/disconnect events and for the controller list to fill
// in (a controller paired before the app launched can be missing from
// +controllers until it reconnects), asks the framework to look for wireless
// controllers, and listens to each controller's input, so pressing a button
// on a paired pad visibly reaches the app. The result is also written to
// Documents/controller-probe.txt.
//
// It sets its own input handler on each controller (a controller has one) and
// puts back the one it found when it ends, unless something else replaced it
// meanwhile. A second call while one is running reports that and changes
// nothing. Not for use while a game is running.
void TKControllerProbeRun(NSTimeInterval seconds, void (^report)(NSString *text, BOOL finished));

// For a game run with --trace-controllers or the Documents/trace-controllers
// marker: writes to `log` the controllers the framework lists at the start
// (name, profiles, elements), then each connect, disconnect and
// became-current notification with the list's new size. Without the argument
// or the marker it does nothing.
//
// Observation only: it reads the framework and listens to its notifications.
// It replaces no method and sets no handler, so it cannot change what the
// guest's own controller code sees or receives. Safe to call for every run in
// a process: the observers are added once and later calls only move the
// output to the new log (or stop it, when the trace is no longer asked for).
void TKControllerProbeStartLogging(FILE *_Nullable log);

NS_ASSUME_NONNULL_END
