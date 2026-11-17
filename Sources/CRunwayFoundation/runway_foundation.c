// A fix for swift-corelibs-foundation's Core Foundation, applied when the
// program loads.
//
// CFEqual and CFHash find an object's CF type in the word after its Swift
// header (CFRuntimeBase's `_cfinfo`). Foundation's own bridged classes keep
// their CF info there, but an app's NSObject subclass (NSFont, NSColor, a
// paragraph style, any custom attribute value) has no such field: the word
// is its first stored property, and when that happens to decode as type 0
// ("Not A Type"), CF calls that class's callbacks, which halt. So an
// NSMutableAttributedString with two adjacent runs holding different such
// objects crashes: inserting a run compares its attributes with its
// neighbour's to coalesce them (CFRunArrayInsert → CFBasicHashesAreEqual →
// CFEqual).
//
// Anything CF meets as "Not A Type" is a Swift object (real CF objects
// always have a registered type), so the fix gives that class equality and
// hashing by the Swift object's own `isEqual(_:)` and `hash`, through the
// bridge Foundation already installs for Swift objects. Nonzero garbage
// types already reach the bridge (their isa never matches the type's class).

#include "runway_foundation.h"

#if defined(__linux__)
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// CFRuntimeClass (CFRuntime.h), up to the members patched here.
typedef struct {
    long version;
    const char *className;
    void (*init)(const void *);
    const void *(*copy)(const void *, const void *);
    void (*finalize)(const void *);
    unsigned char (*equal)(const void *, const void *);
    unsigned long (*hash)(const void *);
} RunwayCFRuntimeClass;

// The start of __CFSwiftBridge: its NSObject part (ForSwiftFoundationOnly.h).
typedef struct {
    unsigned long (*cfTypeID)(const void *);
    unsigned long (*hash)(const void *);
    bool (*isEqual)(const void *, const void *);
} RunwayNSObjectBridge;

static const RunwayNSObjectBridge *bridge;
static int installed;

static unsigned char swift_equal(const void *a, const void *b) {
    if (a == b) return 1;
    if (!a || !b || !bridge || !bridge->isEqual) return 0;
    return bridge->isEqual(a, b) ? 1 : 0;
}

static unsigned long swift_hash(const void *a) {
    if (!a || !bridge || !bridge->hash) return (unsigned long)(uintptr_t)a;
    return bridge->hash(a);
}

__attribute__((constructor)) static void runway_cf_install(void) {
    const RunwayCFRuntimeClass *(*get)(unsigned long) = (const RunwayCFRuntimeClass *(*)(unsigned long))dlsym(RTLD_DEFAULT, "_CFRuntimeGetClassWithTypeID");
    bridge = (const RunwayNSObjectBridge *)dlsym(RTLD_DEFAULT, "__CFSwiftBridge");
    if (!get || !bridge) return;
    RunwayCFRuntimeClass *cls = (RunwayCFRuntimeClass *)get(0);
    if (!cls || !cls->className || strcmp(cls->className, "Not A Type") != 0) return;
    // The class is constant data: make its page writable for the two pointers.
    long page = sysconf(_SC_PAGESIZE);
    uintptr_t start = (uintptr_t)&cls->equal & ~(uintptr_t)(page - 1);
    uintptr_t end = ((uintptr_t)(&cls->hash + 1) + page - 1) & ~(uintptr_t)(page - 1);
    if (mprotect((void *)start, end - start, PROT_READ | PROT_WRITE) != 0) return;
    cls->equal = swift_equal;
    cls->hash = swift_hash;
    mprotect((void *)start, end - start, PROT_READ);
    installed = 1;
}

int runway_cf_swift_equality_installed(void) { return installed; }

#else
int runway_cf_swift_equality_installed(void) { return 0; }
#endif
