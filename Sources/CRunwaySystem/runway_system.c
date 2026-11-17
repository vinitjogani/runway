#include "runway_system.h"

#if defined(_WIN32)
#include <windows.h>
#pragma comment(lib, "synchronization.lib")
static void wait_on(uint32_t *word, uint32_t value) { WaitOnAddress(word, &value, sizeof value, INFINITE); }
static void wake_one(uint32_t *word) { WakeByAddressSingle(word); }
#elif defined(__linux__)
#include <linux/futex.h>
#include <sys/syscall.h>
#include <unistd.h>
static void wait_on(uint32_t *word, uint32_t value) { syscall(SYS_futex, word, FUTEX_WAIT_PRIVATE, value, NULL, NULL, 0); }
static void wake_one(uint32_t *word) { syscall(SYS_futex, word, FUTEX_WAKE_PRIVATE, 1, NULL, NULL, 0); }
#else
#include <sched.h>
static void wait_on(uint32_t *word, uint32_t value) { (void)word; (void)value; sched_yield(); }
static void wake_one(uint32_t *word) { (void)word; }
#endif

static uint32_t cas(uint32_t *word, uint32_t expected, uint32_t desired) {
    __atomic_compare_exchange_n(word, &expected, desired, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED);
    return expected;
}

// Drepper's three-state mutex ("Futexes Are Tricky", mutex 3).
void runway_unfair_lock_lock(uint32_t *word) {
    uint32_t c = cas(word, 0, 1);
    if (c == 0) return;
    for (int spin = 0; spin < 64 && c != 0; spin++) {
        c = cas(word, 0, 1);
        if (c == 0) return;
    }
    if (c != 2) c = __atomic_exchange_n(word, 2, __ATOMIC_ACQUIRE);
    while (c != 0) {
        wait_on(word, 2);
        c = __atomic_exchange_n(word, 2, __ATOMIC_ACQUIRE);
    }
}

int runway_unfair_lock_trylock(uint32_t *word) { return cas(word, 0, 1) == 0; }

void runway_unfair_lock_unlock(uint32_t *word) {
    if (__atomic_fetch_sub(word, 1, __ATOMIC_RELEASE) != 1) {
        __atomic_store_n(word, 0, __ATOMIC_RELEASE);
        wake_one(word);
    }
}

int runway_unfair_lock_is_locked(uint32_t *word) { return __atomic_load_n(word, __ATOMIC_RELAXED) != 0; }
