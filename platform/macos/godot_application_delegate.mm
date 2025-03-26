/**************************************************************************/
/*  godot_application_delegate.mm                                         */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#import "godot_application_delegate.h"

#import "display_server_macos.h"
#import "native_menu_macos.h"
#import "os_macos.h"

@implementation GodotApplicationDelegate

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
	return YES;
}

- (NSArray<NSString *> *)localizedTitlesForItem:(id)item {
	NSArray *item_name = @[ item[1] ];
	return item_name;
}

- (void)searchForItemsWithSearchString:(NSString *)searchString resultLimit:(NSInteger)resultLimit matchedItemHandler:(void (^)(NSArray *items))handleMatchedItems {
	NSMutableArray *found_items = [[NSMutableArray alloc] init];

	DisplayServerMacOS *ds = Object::cast_to<DisplayServerMacOS>(DisplayServer::get_singleton());
	if (ds && ds->_help_get_search_callback().is_valid()) {
		Callable cb = ds->_help_get_search_callback();

		Variant ret;
		Variant search_string = String::utf8([searchString UTF8String]);
		Variant result_limit = (uint64_t)resultLimit;
		Callable::CallError ce;
		const Variant *args[2] = { &search_string, &result_limit };

		cb.callp(args, 2, ret, ce);
		if (ce.error != Callable::CallError::CALL_OK) {
			ERR_PRINT(vformat(RTR("Failed to execute help search callback: %s."), Variant::get_callable_error_text(cb, args, 2, ce)));
		}
		Dictionary results = ret;
		for (const Variant *E = results.next(); E; E = results.next(E)) {
			const String &key = *E;
			const String &value = results[*E];
			if (key.length() > 0 && value.length() > 0) {
				NSArray *item = @[ [NSString stringWithUTF8String:key.utf8().get_data()], [NSString stringWithUTF8String:value.utf8().get_data()] ];
				[found_items addObject:item];
			}
		}
	}

	handleMatchedItems(found_items);
}

- (void)performActionForItem:(id)item {
	DisplayServerMacOS *ds = Object::cast_to<DisplayServerMacOS>(DisplayServer::get_singleton());
	if (ds && ds->_help_get_action_callback().is_valid()) {
		Callable cb = ds->_help_get_action_callback();

		Variant ret;
		Variant item_string = String::utf8([item[0] UTF8String]);
		Callable::CallError ce;
		const Variant *args[1] = { &item_string };

		cb.callp(args, 1, ret, ce);
		if (ce.error != Callable::CallError::CALL_OK) {
			ERR_PRINT(vformat(RTR("Failed to execute help action callback: %s."), Variant::get_callable_error_text(cb, args, 1, ce)));
		}
	}
}

- (void)forceUnbundledWindowActivationHackStep1 {
	// Step 1: Switch focus to macOS SystemUIServer process.
	// Required to perform step 2, TransformProcessType will fail if app is already the in focus.
	for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.systemuiserver"]) {
		[app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
		break;
	}
	[self performSelector:@selector(forceUnbundledWindowActivationHackStep2)
			   withObject:nil
			   afterDelay:0.02];
}

- (void)forceUnbundledWindowActivationHackStep2 {
	// Step 2: Register app as foreground process.
	ProcessSerialNumber psn = { 0, kCurrentProcess };
	(void)TransformProcessType(&psn, kProcessTransformToForegroundApplication);
	[self performSelector:@selector(forceUnbundledWindowActivationHackStep3) withObject:nil afterDelay:0.02];
}

- (void)forceUnbundledWindowActivationHackStep3 {
	// Step 3: Switch focus back to app window.
	[[NSRunningApplication currentApplication] activateWithOptions:NSApplicationActivateIgnoringOtherApps];
}

- (void)system_theme_changed:(NSNotification *)notification {
	DisplayServerMacOS *ds = Object::cast_to<DisplayServerMacOS>(DisplayServer::get_singleton());
	if (ds) {
		ds->emit_system_theme_changed();
	}
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
	static_cast<OS_MacOS *>(OS::get_singleton())->start_main();
}

- (void)activate {
	[NSApp activateIgnoringOtherApps:YES];

	NSString *nsappname = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleName"];
	const char *bundled_id = getenv("__CFBundleIdentifier");
	NSString *nsbundleid_env = [NSString stringWithUTF8String:(bundled_id != nullptr) ? bundled_id : ""];
	NSString *nsbundleid = [[NSBundle mainBundle] bundleIdentifier];
	if (nsappname == nil || isatty(STDOUT_FILENO) || isatty(STDIN_FILENO) || isatty(STDERR_FILENO) || ![nsbundleid isEqualToString:nsbundleid_env]) {
		// If the executable is started from terminal or is not bundled, macOS WindowServer won't register and activate app window correctly (menu and title bar are grayed out and input ignored).
		[self performSelector:@selector(forceUnbundledWindowActivationHackStep1) withObject:nil afterDelay:0.02];
	}
	[[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(system_theme_changed:) name:@"AppleInterfaceThemeChangedNotification" object:nil];
	[[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(system_theme_changed:) name:@"AppleColorPreferencesChangedNotification" object:nil];
}

- (id)init {
	self = [super init];
	return self;
}

- (void)dealloc {
	[[NSDistributedNotificationCenter defaultCenter] removeObserver:self name:@"AppleInterfaceThemeChangedNotification" object:nil];
	[[NSDistributedNotificationCenter defaultCenter] removeObserver:self name:@"AppleColorPreferencesChangedNotification" object:nil];
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
	OS_MacOS *os = (OS_MacOS *)OS::get_singleton();
	if (!os) {
		return;
	}
	List<String> args;
	for (NSURL *url in urls) {
		if ([url isFileURL]) {
			args.push_back(String::utf8([url.path UTF8String]));
		} else {
			args.push_back(vformat("--uri=\"%s\"", String::utf8([url.absoluteString UTF8String])));
		}
	}
	if (!args.is_empty()) {
		if (os->get_main_loop()) {
			// Application is already running, open a new instance with the URL/files as command line arguments.
			os->create_instance(args);
		} else if (os->get_cmd_argc() == 0) {
			// Application is just started, add to the list of command line arguments and continue.
			os->set_cmdline_platform_args(args);
		}
	}
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
	OS_MacOS *os = (OS_MacOS *)OS::get_singleton();
	if (!os) {
		return;
	}
	List<String> args;
	for (NSString *filename in filenames) {
		NSURL *url = [NSURL URLWithString:filename];
		args.push_back(String::utf8([url.path UTF8String]));
	}
	if (!args.is_empty()) {
		if (os->get_main_loop()) {
			// Application is already running, open a new instance with the URL/files as command line arguments.
			os->create_instance(args);
		} else if (os->get_cmd_argc() == 0) {
			// Application is just started, add to the list of command line arguments and continue.
			os->set_cmdline_platform_args(args);
		}
	}
}

- (void)applicationDidResignActive:(NSNotification *)notification {
	DisplayServerMacOS *ds = Object::cast_to<DisplayServerMacOS>(DisplayServer::get_singleton());
	if (ds) {
		ds->mouse_process_popups(true);
	}
	if (OS::get_singleton()->get_main_loop()) {
		OS::get_singleton()->get_main_loop()->notification(MainLoop::NOTIFICATION_APPLICATION_FOCUS_OUT);
	}
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
	if (OS::get_singleton()->get_main_loop()) {
		OS::get_singleton()->get_main_loop()->notification(MainLoop::NOTIFICATION_APPLICATION_FOCUS_IN);
	}
}

- (void)globalMenuCallback:(id)sender {
	DisplayServerMacOS *ds = Object::cast_to<DisplayServerMacOS>(DisplayServer::get_singleton());
	if (ds) {
		return ds->menu_callback(sender);
	}
}

- (NSMenu *)applicationDockMenu:(NSApplication *)sender {
	if (NativeMenu::get_singleton()) {
		NativeMenuMacOS *nmenu = (NativeMenuMacOS *)NativeMenu::get_singleton();
		return nmenu->_get_dock_menu();
	} else {
		return nullptr;
	}
}

- (void)applicationWillTerminate:(NSNotification *)notification {
	OS_MacOS *os = (OS_MacOS *)OS::get_singleton();
	if (os) {
		os->cleanup();
		exit(os->get_exit_code());
	}
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
	DisplayServerMacOS *ds = Object::cast_to<DisplayServerMacOS>(DisplayServer::get_singleton());
	if (ds && ds->has_window(DisplayServerMacOS::MAIN_WINDOW_ID)) {
		ds->send_window_event(ds->get_window(DisplayServerMacOS::MAIN_WINDOW_ID), DisplayServerMacOS::WINDOW_EVENT_CLOSE_REQUEST);
	}
	OS_MacOS *os = (OS_MacOS *)OS::get_singleton();
	if (!os || os->os_should_terminate()) {
		return NSTerminateNow;
	}
	return NSTerminateCancel;
}

- (void)showAbout:(id)sender {
	OS_MacOS *os = (OS_MacOS *)OS::get_singleton();
	if (os && os->get_main_loop()) {
		os->get_main_loop()->notification(MainLoop::NOTIFICATION_WM_ABOUT);
	}
}

@end
