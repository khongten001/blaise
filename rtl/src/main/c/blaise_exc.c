/*
 * Blaise — An Object Pascal Compiler
 * Copyright (c) 2026 Graeme Geldenhuys
 * SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
 * Licensed under the Apache License v2.0 with Runtime Library Exception.
 * See LICENSE file in the project root for full license terms.
 *
 * Blaise RTL — Exception frame management (Phase 2)
 *
 * Uses setjmp/longjmp for exception dispatch.  Each try block allocates a
 * BlaiseExcFrame on the Pascal stack.  jbuf MUST be at offset 0 so the
 * compiler can pass the frame pointer directly to setjmp.
 *
 * Frame size contract: the compiler allocates BLAISE_EXC_FRAME_ALLOC16 * 16
 * bytes (currently 512) for each try block via QBE alloc16.  This must be >=
 * sizeof(BlaiseExcFrame) on every supported target.
 *
 *   Linux x86_64:  sizeof(jmp_buf) = 200 → frame = 216 bytes  < 512 ✓
 *   macOS ARM64:   sizeof(jmp_buf) ≈ 312 → frame = 328 bytes  < 512 ✓
 */

#include <setjmp.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

/* Forward-declared string helper to build a Blaise string from a C string. */
static void* exc_str_from_cstr(const char* s) {
    typedef struct { int32_t refcnt; int32_t length; int32_t capacity; } StrHdr;
    int32_t len = s ? (int32_t)strlen(s) : 0;
    StrHdr* h = (StrHdr*)malloc(sizeof(StrHdr) + len + 1);
    if (!h) return NULL;
    h->refcnt = 0; h->length = len; h->capacity = len;
    if (len > 0) memcpy((char*)(h + 1), s, (size_t)len);
    ((char*)(h + 1))[len] = '\0';
    return (void*)h;
}

typedef struct BlaiseExcFrame {
    jmp_buf jbuf;       /* offset 0 — frame ptr passed directly to setjmp   */
    void*   exception;  /* live exception object; NULL on normal path        */
    void*   prev;       /* previous BlaiseExcFrame* in the thread-local chain */
} BlaiseExcFrame;

#ifdef _WIN32
static __declspec(thread) BlaiseExcFrame* g_exc_top        = NULL;
static __declspec(thread) void*           g_current_exception = NULL;
#else
static __thread BlaiseExcFrame* g_exc_top        = NULL;
static __thread void*           g_current_exception = NULL;
#endif

/*
 * _PushExcFrame — link a new exception frame into the thread-local chain.
 * Called by the compiler BEFORE setjmp at the start of every try block.
 */
void _PushExcFrame(void* frame) {
    BlaiseExcFrame* f = (BlaiseExcFrame*)frame;
    f->exception = NULL;
    f->prev      = (void*)g_exc_top;
    g_exc_top    = f;
}

/*
 * _PopExcFrame — unlink the top frame.
 * Called on normal exit from a try scope or at the start of an except/finally
 * handler before running handler body.
 */
void _PopExcFrame(void) {
    if (g_exc_top)
        g_exc_top = (BlaiseExcFrame*)g_exc_top->prev;
}

/*
 * _Raise — raise an exception.  Sets obj on the current frame and longjmps.
 * Aborts if no active handler exists (unhandled exception).
 */
void _Raise(void* obj) {
    if (!g_exc_top)
        abort();
    g_current_exception  = obj;
    g_exc_top->exception = obj;
    longjmp(*(jmp_buf*)g_exc_top, 1);
}

/*
 * _CurrentException — return the live exception object.
 * Called from an except handler to capture the exception pointer.
 * Uses g_current_exception (set by _Raise) rather than g_exc_top->exception
 * so that bare re-raise inside a typed handler continues to work after
 * _PopExcFrame has already unwound the handler's own frame.
 */
void* _CurrentException(void) {
    return g_current_exception;
}

/*
 * _CurrentExceptionMessage — return the Message string of the current exception.
 * Class layout: offset 0 = vptr (8 bytes), offset 8 = FMessage (string pointer).
 * Returns an empty string if no exception is active.
 */
void* _CurrentExceptionMessage(void) {
    /* Use g_current_exception rather than g_exc_top->exception: the codegen
       calls _PopExcFrame() before running the except body, so g_exc_top has
       already been unwound by the time CurrentExceptionMessage is called. */
    void* exc = g_current_exception;
    if (!exc) return exc_str_from_cstr("");
    /* FMessage is the first user field, after the 8-byte vptr */
    void* msg = *((void**)((char*)exc + 8));
    return msg ? msg : exc_str_from_cstr("");
}

/*
 * _Reraise — re-raise the given exception to the enclosing handler.
 * Called by the compiler on the exception path of try/finally, after
 * _PopExcFrame has already unlinked the try block's own frame.
 */
void _Reraise(void* exc) {
    _Raise(exc);
}

/* -----------------------------------------------------------------------
 * Type identity — is / as operators
 * ----------------------------------------------------------------------- */

/*
 * BlaiseTypeInfo — one per class/interface, stored as vtable slot 0.
 * parent   = pointer to parent class TypeInfo, or NULL for root classes.
 * impllist = NULL-terminated array of {typeinfo_intf*, itab*} pairs, or NULL
 *            if the class implements no interfaces.
 */
typedef struct BlaiseTypeInfo {
    const struct BlaiseTypeInfo* parent;
    const void**                 impllist;
} BlaiseTypeInfo;

/*
 * _IsInstance — runtime 'is' check for class inheritance.
 * Walks the TypeInfo parent chain from the object's own TypeInfo upward.
 * Returns 1 if the object is an instance of target (or a subclass), else 0.
 * obj must be non-nil and point to an instance whose first field is the vptr.
 */
int _IsInstance(void* obj, const BlaiseTypeInfo* target) {
    const BlaiseTypeInfo* ti;
    void** vtable;
    if (!obj || !target) return 0;
    vtable = *(void***)obj;      /* obj[0] = vptr */
    ti     = (const BlaiseTypeInfo*)vtable[0];  /* vtable[0] = typeinfo */
    while (ti) {
        if (ti == target) return 1;
        ti = ti->parent;
    }
    return 0;
}

/*
 * _ImplementsInterface — runtime 'is' check for interface membership.
 * Walks the class TypeInfo chain; at each level searches the impllist for
 * a matching interface TypeInfo pointer.
 * Returns 1 if the object's class (or any ancestor) implements the interface.
 */
int _ImplementsInterface(void* obj, const BlaiseTypeInfo* intf_ti) {
    const BlaiseTypeInfo* ti;
    const void**          impl;
    void**                vtable;
    if (!obj || !intf_ti) return 0;
    vtable = *(void***)obj;
    ti     = (const BlaiseTypeInfo*)vtable[0];
    while (ti) {
        impl = ti->impllist;
        while (impl && *impl) {
            if ((const BlaiseTypeInfo*)(*impl) == intf_ti) return 1;
            impl += 2;  /* each entry is {typeinfo*, itab*} — skip both */
        }
        ti = ti->parent;
    }
    return 0;
}

/*
 * _GetItab — return the itab pointer for the given object/interface pair.
 * Walks the class TypeInfo chain searching the impllist for a matching
 * interface TypeInfo pointer; returns the associated itab on match.
 * Returns NULL if the object's class does not implement the interface.
 */
const void* _GetItab(void* obj, const BlaiseTypeInfo* intf_ti) {
    const BlaiseTypeInfo* ti;
    const void**          impl;
    void**                vtable;
    if (!obj || !intf_ti) return 0;
    vtable = *(void***)obj;
    ti     = (const BlaiseTypeInfo*)vtable[0];
    while (ti) {
        impl = ti->impllist;
        while (impl && *impl) {
            if ((const BlaiseTypeInfo*)(*impl) == intf_ti) return *(impl + 1);
            impl += 2;
        }
        ti = ti->parent;
    }
    return 0;
}

/*
 * _Raise_InvalidCast — raised by the 'as' operator when the type check fails.
 */
void _Raise_InvalidCast(void) {
    abort();
}
