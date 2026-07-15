// Rounds the corners of this app's macOS window(s) after the fact.
//
// app.zon declares `.titlebar = "chromeless"` for the main window (this
// app draws its own dark chrome and its own HTML traffic-light buttons --
// see App.tsx's `window-controls--mac` cluster). @native-sdk/cli's AppKit
// host (src/platform/macos/appkit_host.m, createWindowWithId:) maps that
// style to `NSWindowStyleMaskBorderless`, and AppKit only auto-rounds
// `NSWindowStyleMaskTitled` windows -- a borderless window's hardware
// corners render square. That mapping is shared with `.hidden_inset` /
// `.hidden_inset_tall` (which DO stay Titled and round fine) and with the
// Windows host's own reading of the same `titlebar` value (chromeless ->
// WS_POPUP there), so switching the app.zon value would also swap Windows
// over to a native caption bar -- not this bug, not this platform.
//
// The window itself lives entirely inside the vendored SDK (createWindowWithId:
// above), which this repo does not patch (see the project's node_modules
// guidance), so this file does the fix from the outside: once the window
// exists and becomes key, mask its content view's layer into a rounded
// rect and make the window's own background transparent so the corners
// outside that rect don't paint square. styleMask itself is left alone,
// so every SDK codepath that branches on it (close/minimize verbs, chrome
// inset reporting, etc. -- all in appkit_host.m) keeps working unchanged.
#import <AppKit/AppKit.h>

// Matches macOS's own window corner radius closely enough that the seam
// between the system-drawn shadow and this layer-clipped content isn't
// noticeable; there is no public API to read the real value.
static const CGFloat kMaatNativeWindowCornerRadius = 10.0;

static void MaatNativeRoundWindowCorners(NSWindow *window) {
    if (!window) return;
    // Titled windows (the `.hidden_inset`/`.hidden_inset_tall` titlebar
    // styles) already get native rounded corners from AppKit -- leave
    // them untouched.
    if (window.styleMask & NSWindowStyleMaskTitled) return;
    NSView *contentView = window.contentView;
    if (!contentView) return;
    contentView.wantsLayer = YES;
    contentView.layer.cornerRadius = kMaatNativeWindowCornerRadius;
    contentView.layer.masksToBounds = YES;
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = YES;
}

@interface MaatNativeWindowCornerObserver : NSObject
@end

@implementation MaatNativeWindowCornerObserver
+ (void)maatNative_windowDidBecomeKey:(NSNotification *)notification {
    MaatNativeRoundWindowCorners((NSWindow *)notification.object);
}
@end

// Called once from `main.zig`'s `pub fn main`, before the SDK's blocking
// run loop starts (so there is no window yet to fix up directly). Instead
// this registers an observer for `NSWindowDidBecomeKeyNotification`, which
// fires for the main window (and any later secondary window) the moment
// the SDK first orders it front -- see appkit_host.m's
// `showDeferredWindowIfPending:`/`makeKeyAndOrderFront:` call sites.
void maat_native_install_macos_window_corner_fixup(void) {
    [[NSNotificationCenter defaultCenter] addObserver:[MaatNativeWindowCornerObserver class]
                                              selector:@selector(maatNative_windowDidBecomeKey:)
                                                  name:NSWindowDidBecomeKeyNotification
                                                object:nil];
}
