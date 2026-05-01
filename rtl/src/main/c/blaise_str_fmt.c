/*
 * Blaise RTL — _StringFormat (variadic; cannot be ported to Pascal)
 *
 * String layout mirrors blaise_str.pas:
 *   [RefCount:4][Length:4][Capacity:4][data...][NUL]
 *
 * All other string functions live in blaise_str.pas.
 */

#include <stdint.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <ctype.h>

#define HDR_SIZE 12

typedef struct {
    int32_t refcnt;
    int32_t length;
    int32_t capacity;
} BlaiseStrHdr;

static inline const char* str_data(void* ptr) {
    return (const char*)ptr + HDR_SIZE;
}

static inline int32_t str_len(void* ptr) {
    if (!ptr) return 0;
    return ((BlaiseStrHdr*)ptr)->length;
}

static void* str_alloc(int32_t len) {
    BlaiseStrHdr* h = malloc(sizeof(BlaiseStrHdr) + (size_t)len + 1);
    if (!h) return NULL;
    h->refcnt   = 0;
    h->length   = len;
    h->capacity = len;
    ((char*)(h + 1))[len] = '\0';
    return h;
}

/* ------------------------------------------------------------------ */
/* _StringFormat(fmt, ...) : string                                     */
/*                                                                      */
/* Variadic: after the format string pointer, each format argument      */
/* is passed as a (tag: int, value: int or void*) pair:                 */
/*   tag=0 → int32 value (matched to %d in format)                     */
/*   tag=1 → void* Blaise string (matched to %s in format)             */
/* ------------------------------------------------------------------ */
void* _StringFormat(void* fmt, ...) {
    const char* f    = str_data(fmt);
    int         flen = str_len(fmt);

    va_list ap1, ap2;
    va_start(ap1, fmt);
    va_copy(ap2, ap1);

    /* Pass 1: compute output length */
    size_t out_len = 0;
    const char* p   = f;
    const char* end = f + flen;
    while (p < end) {
        if (*p == '%' && p + 1 < end) {
            p++;
            if (*p == 'd') {
                int tag = va_arg(ap1, int);
                if (tag == 0) {
                    int32_t v = (int32_t)va_arg(ap1, int);
                    char tmp[24];
                    out_len += (size_t)snprintf(tmp, sizeof(tmp), "%d", v);
                } else {
                    void* sv = va_arg(ap1, void*);
                    out_len += (size_t)str_len(sv);
                }
                p++;
            } else if (*p == 's') {
                int tag = va_arg(ap1, int);
                if (tag == 1) {
                    void* sv = va_arg(ap1, void*);
                    out_len += (size_t)str_len(sv);
                } else {
                    int32_t v = (int32_t)va_arg(ap1, int);
                    char tmp[24];
                    out_len += (size_t)snprintf(tmp, sizeof(tmp), "%d", v);
                }
                p++;
            } else if (*p == '%') {
                out_len++;
                p++;
            } else {
                out_len++;
                p++;
            }
        } else {
            out_len++;
            p++;
        }
    }
    va_end(ap1);

    void* result = str_alloc((int32_t)out_len);
    if (!result) { va_end(ap2); return NULL; }
    char* dst = (char*)result + HDR_SIZE;

    /* Pass 2: fill buffer */
    p = f;
    while (p < end) {
        if (*p == '%' && p + 1 < end) {
            p++;
            if (*p == 'd') {
                int tag = va_arg(ap2, int);
                int32_t v;
                if (tag == 0)
                    v = (int32_t)va_arg(ap2, int);
                else {
                    void* sv = va_arg(ap2, void*);
                    v = 0; (void)sv;
                }
                dst += sprintf(dst, "%d", v);
                p++;
            } else if (*p == 's') {
                int tag = va_arg(ap2, int);
                if (tag == 1) {
                    void* sv = va_arg(ap2, void*);
                    int32_t slen = str_len(sv);
                    if (slen > 0)
                        memcpy(dst, str_data(sv), (size_t)slen);
                    dst += slen;
                } else {
                    int32_t v = (int32_t)va_arg(ap2, int);
                    dst += sprintf(dst, "%d", v);
                }
                p++;
            } else if (*p == '%') {
                *dst++ = '%';
                p++;
            } else {
                *dst++ = '%';
                *dst++ = *p++;
            }
        } else {
            *dst++ = *p++;
        }
    }
    va_end(ap2);
    *dst = '\0';
    return result;
}
