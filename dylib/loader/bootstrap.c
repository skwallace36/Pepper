// C constructor — fires when the dylib is loaded via DYLD_INSERT_LIBRARIES.
// Calls into Swift to register the control plane bootstrap.

extern void PepperBootstrap(void);

__attribute__((constructor))
static void pepper_constructor(void) {
    PepperBootstrap();
}
