/*
 * Blaise — An Object Pascal Compiler
 * Copyright (c) 2026 Graeme Geldenhuys
 * SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
 * Licensed under the Apache License v2.0 with Runtime Library Exception.
 * See LICENSE file in the project root for full license terms.
 *
 * Blaise RTL — float support functions.
 *
 * _DoubleToStr / _SingleToStr : convert float to Blaise string (ARC heap).
 * _StrToDouble                : convert Blaise string to double.
 * _AbsInt / _AbsInt64         : absolute value for integer types.
 *
 * String memory layout (same as all other Blaise strings):
 *   data_ptr - 12 : refcount  (int32)
 *   data_ptr -  8 : length    (int32)
 *   data_ptr -  4 : capacity  (int32)
 *   data_ptr +  0 : char data + NUL
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

#define HDR_SIZE 12

static void* blaise_alloc_str(const char* src, int32_t len)
{
    int32_t cap  = len + 1;
    char*   base = (char*)malloc(HDR_SIZE + cap);
    if (!base) return NULL;
    *(int32_t*)(base)     = 1;    /* refcount */
    *(int32_t*)(base + 4) = len;  /* length   */
    *(int32_t*)(base + 8) = cap;  /* capacity */
    char* data = base + HDR_SIZE;
    memcpy(data, src, len);
    data[len] = '\0';
    return (void*)data;
}

void* _DoubleToStr(double v)
{
    char buf[64];
    /* Use 'g' format: shortest representation that round-trips.
       Fall back to full precision if needed. */
    int n = snprintf(buf, sizeof(buf), "%.15g", v);
    if (n < 0 || n >= (int)sizeof(buf)) {
        snprintf(buf, sizeof(buf), "%f", v);
        n = (int)strlen(buf);
    }
    return blaise_alloc_str(buf, n);
}

void* _SingleToStr(float v)
{
    char buf[32];
    int n = snprintf(buf, sizeof(buf), "%.7g", (double)v);
    if (n < 0 || n >= (int)sizeof(buf)) n = (int)strlen(buf);
    return blaise_alloc_str(buf, n);
}

double _StrToDouble(void* s)
{
    if (!s) return 0.0;
    return strtod((const char*)s, NULL);
}

int32_t _AbsInt(int32_t n)
{
    return n < 0 ? -n : n;
}

int64_t _AbsInt64(int64_t n)
{
    return n < 0 ? -n : n;
}
