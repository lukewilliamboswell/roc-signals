int main(int argc, char **argv) { (void)argc; (void)argv; return 0; }
#include <stdlib.h>
#include <stdio.h>
#include <stddef.h>
void *roc_alloc(size_t n, size_t a) { if (a > _Alignof(max_align_t)) abort(); void *p = malloc(n ? n : 1); if (!p) abort(); return p; }
void roc_dealloc(void *p, size_t a) { (void)a; free(p); }
void *roc_realloc(void *p, size_t n, size_t a) { if (a > _Alignof(max_align_t)) abort(); void *q = realloc(p, n ? n : 1); if (!q) abort(); return q; }
void roc_dbg(const char *p, size_t n) { fwrite(p, 1, n, stderr); }
void roc_expect_failed(const char *p, size_t n) { roc_dbg(p, n); abort(); }
void roc_crashed(const char *p, size_t n) { roc_dbg(p, n); abort(); }
