// Small native helpers for Runway's system frameworks that Swift can't
// express directly: atomics + futex/WaitOnAddress for os_unfair_lock.
#ifndef RUNWAY_SYSTEM_H
#define RUNWAY_SYSTEM_H

#include <stdint.h>

/// A 32-bit unfair lock word: 0 unlocked, 1 locked, 2 locked with waiters.
void runway_unfair_lock_lock(uint32_t *word);
int runway_unfair_lock_trylock(uint32_t *word);
void runway_unfair_lock_unlock(uint32_t *word);
/// Whether the word is currently held (by anyone).
int runway_unfair_lock_is_locked(uint32_t *word);

#endif
