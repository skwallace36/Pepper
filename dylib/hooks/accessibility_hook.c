// accessibility_hook.c — DYLD_INTERPOSE for UIAccessibilityIsVoiceOverRunning
//
// Many SwiftUI apps only populate accessibility labels when VoiceOver is active.
// Combined with the VoiceOverTouchEnabled simulator preference (set by deploy),
// this ensures Pepper gets full labels from apps like Ice Cubes.

#include <stdbool.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee }

extern bool UIAccessibilityIsVoiceOverRunning(void);

static bool pepper_UIAccessibilityIsVoiceOverRunning(void) {
    return true;
}

DYLD_INTERPOSE(pepper_UIAccessibilityIsVoiceOverRunning, UIAccessibilityIsVoiceOverRunning);
