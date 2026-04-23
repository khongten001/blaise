/*
 * Blaise RTL — file I/O, CLI, and process primitives
 *
 * All functions that return a Blaise string allocate a fresh header with
 * RefCount = 0 (unowned). The compiler's ARC wrapper calls _StringAddRef
 * at the assignment site.
 *
 * String representation (shared with blaise_str.c):
 *   +--[4 bytes]--+--[4 bytes]--+--[4 bytes]--+--[N bytes]--+--[1 byte]--+
 *   | RefCount    | Length      | Capacity    | UTF-8 data  | NUL        |
 *   +-------------+-------------+-------------+-------------+------------+
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ------------------------------------------------------------------ */
/* String header (mirrors blaise_str.c)                                */
/* ------------------------------------------------------------------ */

typedef struct {
    int32_t refcnt;
    int32_t length;
    int32_t capacity;
    /* char data[]; follows immediately */
} BlaiseStrHdr;

static inline const char* io_str_data(void* ptr) {
    return ptr ? (const char*)ptr + sizeof(BlaiseStrHdr) : "";
}

static inline int32_t io_str_len(void* ptr) {
    return ptr ? ((BlaiseStrHdr*)ptr)->length : 0;
}

static void* io_str_alloc(int32_t len) {
    BlaiseStrHdr* h = (BlaiseStrHdr*)malloc(sizeof(BlaiseStrHdr) + len + 1);
    if (!h) return NULL;
    h->refcnt   = 0;
    h->length   = len;
    h->capacity = len;
    ((char*)(h + 1))[len] = '\0';
    return (void*)h;
}

/* Build a Blaise string from a C string (may be NULL → empty). */
static void* io_str_from_cstr(const char* s) {
    int32_t len = s ? (int32_t)strlen(s) : 0;
    void*   r   = io_str_alloc(len);
    if (r && len > 0)
        memcpy((char*)r + sizeof(BlaiseStrHdr), s, (size_t)len);
    return r;
}

/* ------------------------------------------------------------------ */
/* Global argc / argv — set by _SetArgs before Blaise main runs       */
/* ------------------------------------------------------------------ */

static int    g_argc = 0;
static char** g_argv = NULL;

void _SetArgs(int32_t argc, char** argv) {
    g_argc = (int)argc;
    g_argv = argv;
}

/* ------------------------------------------------------------------ */
/* _ParamCount() : Integer                                              */
/* Returns the number of command-line arguments (excluding program).   */
/* ------------------------------------------------------------------ */

int32_t _ParamCount(void) {
    return g_argc > 0 ? g_argc - 1 : 0;
}

/* ------------------------------------------------------------------ */
/* _ParamStr(Index) : string                                            */
/* 0 = program name; 1..ParamCount = arguments.                        */
/* ------------------------------------------------------------------ */

void* _ParamStr(int32_t index) {
    if (g_argv == NULL || index < 0 || index >= g_argc)
        return io_str_from_cstr("");
    return io_str_from_cstr(g_argv[index]);
}

/* ------------------------------------------------------------------ */
/* _ReadFile(FileName) : string                                         */
/* Reads the entire file into a Blaise string. Returns empty on error. */
/* ------------------------------------------------------------------ */

void* _ReadFile(void* filename) {
    const char* path = io_str_data(filename);
    FILE*       f    = fopen(path, "rb");
    if (!f) return io_str_from_cstr("");

    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    rewind(f);

    if (sz < 0) { fclose(f); return io_str_from_cstr(""); }

    void* r = io_str_alloc((int32_t)sz);
    if (!r) { fclose(f); return NULL; }

    size_t n = fread((char*)r + sizeof(BlaiseStrHdr), 1, (size_t)sz, f);
    fclose(f);
    ((BlaiseStrHdr*)r)->length   = (int32_t)n;
    ((BlaiseStrHdr*)r)->capacity = (int32_t)n;
    ((char*)r + sizeof(BlaiseStrHdr))[n] = '\0';
    return r;
}

/* ------------------------------------------------------------------ */
/* _WriteFile(FileName, Content)                                        */
/* Writes (overwrites) a Blaise string to a file.                      */
/* ------------------------------------------------------------------ */

void _WriteFile(void* filename, void* content) {
    const char* path = io_str_data(filename);
    int32_t     len  = io_str_len(content);
    const char* data = io_str_data(content);
    FILE*       f    = fopen(path, "wb");
    if (!f) return;
    if (len > 0) fwrite(data, 1, (size_t)len, f);
    fclose(f);
}

/* ------------------------------------------------------------------ */
/* _AppendFile(FileName, Content)                                       */
/* Appends a Blaise string to a file.                                  */
/* ------------------------------------------------------------------ */

void _AppendFile(void* filename, void* content) {
    const char* path = io_str_data(filename);
    int32_t     len  = io_str_len(content);
    const char* data = io_str_data(content);
    FILE*       f    = fopen(path, "ab");
    if (!f) return;
    if (len > 0) fwrite(data, 1, (size_t)len, f);
    fclose(f);
}

/* ------------------------------------------------------------------ */
/* _FileExists(FileName) : Boolean (0 or 1)                            */
/* ------------------------------------------------------------------ */

int32_t _FileExists(void* filename) {
    const char* path = io_str_data(filename);
    FILE*       f    = fopen(path, "rb");
    if (!f) return 0;
    fclose(f);
    return 1;
}

/* ------------------------------------------------------------------ */
/* _GetEnvVar(Name) : string                                            */
/* Returns the value of environment variable Name, or empty string.    */
/* ------------------------------------------------------------------ */

void* _GetEnvVar(void* name) {
    const char* key = io_str_data(name);
    const char* val = getenv(key);
    return io_str_from_cstr(val ? val : "");
}

/* ------------------------------------------------------------------ */
/* _Exec(Command) : Integer                                             */
/* Runs a shell command via system(). Returns exit status.             */
/* ------------------------------------------------------------------ */

int32_t _Exec(void* cmd) {
    const char* s = io_str_data(cmd);
    int rc = system(s);
#ifdef WEXITSTATUS
    if (rc != -1 && WIFEXITED(rc)) rc = WEXITSTATUS(rc);
#endif
    return (int32_t)rc;
}

/* ------------------------------------------------------------------ */
/* _Halt(ExitCode)                                                      */
/* ------------------------------------------------------------------ */

void _Halt(int32_t code) {
    exit((int)code);
}
