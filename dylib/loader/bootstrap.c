// C constructor — fires when the dylib is loaded via DYLD_INSERT_LIBRARIES.
// Sets minimal accessibility flag, then calls into Swift for control plane.

extern void PepperBootstrap(void);
extern void pepper_activate_accessibility(void);

__attribute__((constructor))
static void pepper_constructor(void) {
    pepper_activate_accessibility();
    PepperBootstrap();
}
