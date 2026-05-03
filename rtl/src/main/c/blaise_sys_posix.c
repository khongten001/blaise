/*
 * Blaise — An Object Pascal Compiler
 * Copyright (c) 2026 Graeme Geldenhuys
 * SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
 * Licensed under the Apache License v2.0 with Runtime Library Exception.
 * See LICENSE file in the project root for full license terms.
 *
 * Blaise RTL — POSIX write wrapper
 *
 * Provides _SysWrite and _SysWriteNewline: thin wrappers around the
 * POSIX write(2) syscall.  No malloc, no format strings, no libc I/O.
 * Higher-level string/int formatting is done in blaise_sys.pas.
 */

#include <unistd.h>
#include <stdint.h>

/* Write exactly len bytes from buf to fd, retrying on short writes. */
void _SysWrite(int32_t fd, const char* buf, int64_t len) {
    const char* p = buf;
    while (len > 0) {
        ssize_t n = write((int)fd, p, (size_t)len);
        if (n <= 0) break;
        p   += n;
        len -= n;
    }
}

void _SysWriteNewline(int32_t fd) {
    char nl = '\n';
    ssize_t r = write((int)fd, &nl, 1);
    (void)r;
}
