// accessibility_hook.c — Early accessibility activation for SwiftUI
//
// SwiftUI only populates accessibility labels when it believes an assistive
// technology is active. This file provides two mechanisms:
// 1. DYLD_INTERPOSE — makes UIAccessibilityIsVoiceOverRunning() return true
// 2. Early API call — sets _AXSApplicationAccessibilitySetEnabled(true) at
//    constructor time so SwiftUI builds its AX tree on first render.

#include <stdbool.h>
#include <dlfcn.h>

// ---------------------------------------------------------------------------
// Layer 1: DYLD_INTERPOSE — catches direct C function calls
// ---------------------------------------------------------------------------

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee }

extern bool UIAccessibilityIsVoiceOverRunning(void);

static bool pepper_UIAccessibilityIsVoiceOverRunning(void) {
    return true;
}

DYLD_INTERPOSE(pepper_UIAccessibilityIsVoiceOverRunning, UIAccessibilityIsVoiceOverRunning);

// ---------------------------------------------------------------------------
// Layer 2: Minimal early activation — called from bootstrap.c
// ---------------------------------------------------------------------------
// Only sets _AXSApplicationAccessibilitySetEnabled — the per-app flag that
// UIHostingViewBase reads to decide whether to enable accessibility.
// Does NOT set the master toggle or VoiceOver override (those caused 30s boot).

void pepper_activate_accessibility(void) {
    void *lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_LAZY);
    if (!lib) return;

    void (*setAppAX)(bool) = dlsym(lib, "_AXSApplicationAccessibilitySetEnabled");
    if (setAppAX) setAppAX(true);
}
