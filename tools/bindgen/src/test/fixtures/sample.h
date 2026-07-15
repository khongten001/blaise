/* bindgen test fixture — one of each declaration shape we harvest. */
#include "sample_dep.h"

#define XPI 3            /* macros are invisible in the AST: must NOT appear */

typedef unsigned long XID;
typedef XID Window;

enum XOrientation { XOrientVertical, XOrientHorizontal = 5, XOrientOther };

typedef struct { int x; unsigned long serial; const char *name; } XPoint;

typedef struct _XDisplay Display;   /* opaque */

typedef int (*XErrorHandler)(Display *dpy, int code);

extern Display *XOpenDisplay(const char *display_name);
extern int XCloseDisplay(Display *dpy);
extern void XFlushNothing(void);
extern XID XCreateThing(Display *dpy, XPoint pt, char **names, double scale);
extern int XVariadicThing(Display *dpy, int mode, ...);
static int hidden_helper(int a) { return a; }

/* Unions: named (used by value, size matters) and anonymous-field. */
typedef union _XSampleEvent {
    int type;
    long pad[24];
} XSampleEvent;

typedef struct {
    int format;
    union {
        char b[20];
        short s[10];
        long l[5];
    } data;
} XSampleMessage;

extern int XSampleNextEvent(Display *dpy, XSampleEvent *ev);

/* Anonymous enum named by typedef (XIMCaretDirection pattern). */
typedef enum {
    XSampleDirForward,
    XSampleDirBackward = 10
} XSampleDirection;

extern void XSampleSetDirection(XSampleDirection dir);

/* Macro constants — invisible in the AST, harvested via -E -dD plus a
   clang-evaluated probe file. */
#define SAMPLE_A 2
#define SAMPLE_MASK (1L<<15)
#define SAMPLE_NEG (-5)
#define SAMPLE_ALL (~0L)
#define SAMPLE_COMBO (SAMPLE_A | SAMPLE_MASK)
#define SAMPLE_STR "hello"
#define SAMPLE_FN(x) ((x)+1)
#define SAMPLE_TYPE int

/* Inline (non-typedef) function-pointer parameter — XIfEvent pattern. */
extern int XSampleIfEvent(Display *dpy, int (*predicate)(Display *, XID), XID arg);
extern int XSampleCheckIfEvent(Display *dpy, int (*predicate)(Display *, XID), XID arg);
/* Variadic function pointer — must degrade to Pointer. */
typedef int (*XSampleVaHandler)(Display *dpy, ...);
