/*
 * Blaise RTL — ARC string management stubs (Phase 2)
 *
 * Phase 2: no-op implementations. nil-safe (null check guards).
 *
 * Phase 3 will implement real reference counting using the locked
 * string header layout:
 *
 *   +--[4 bytes]--+--[4 bytes]--+--[4 bytes]--+--[N bytes]--+--[1 byte]--+
 *   | RefCount    | Length      | Capacity    | UTF-8 data  | NUL        |
 *   +-------------+-------------+-------------+-------------+------------+
 *
 * A RefCount of -1 marks a statically-allocated string (string literals
 * in the data section). _StringAddRef and _StringRelease are no-ops for
 * static strings and nil pointers.
 */

#include <stdint.h>
#include <stdlib.h>

void _StringAddRef(void *ptr) {
    (void)ptr;
    /* Phase 3: if (ptr && *(int32_t*)ptr != -1) ++*(int32_t*)ptr; */
}

void _StringRelease(void *ptr) {
    (void)ptr;
    /* Phase 3:
       if (!ptr) return;
       int32_t *rc = (int32_t*)ptr;
       if (*rc == -1) return;   // static string
       if (--(*rc) == 0) free(ptr);
    */
}
