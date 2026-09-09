#include <stdint.h>
#include <stdlib.h>
extern const void *CFStringCreateWithCString(const void *, const char *, uint32_t);
extern long CFStringGetLength(const void *);
extern void CFRelease(const void *);
extern void *objc_getClass(const char *);
extern char *__cxa_demangle(const char *, char *, size_t *, int *);
int main(void) {
    int status = -1;
    char *demangled = __cxa_demangle("_Z1fv", 0, 0, &status);
    if (!demangled || status != 0) return 2;
    free(demangled);
    const void *s = CFStringCreateWithCString(0, "Roc", 0x08000100);
    if (!s) return 1;
    long length = CFStringGetLength(s);
    CFRelease(s);
    return length != 3 || !objc_getClass("NSObject");
}
