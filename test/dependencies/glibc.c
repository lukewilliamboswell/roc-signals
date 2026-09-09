/* Exercise startup, termination, libc, libm, and pthread entry points. */
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static int state;
__attribute__((constructor)) static void initialize(void) { state = 1; }
__attribute__((destructor)) static void finalize(void) {
    if (state != 3) _Exit(5);
}
static void finished(void) {
    if (state != 2) _Exit(6);
    state = 3;
    puts("PASS: generated glibc startup and link inputs");
}
static void *worker(void *value) { return value; }
int main(void) {
    if (state != 1 || atexit(finished)) return 1;
    volatile double zero = 0.0;
    if (cos(zero) != 1.0) return 2;
    void *allocation = malloc(64);
    if (!allocation) return 3;
    pthread_t thread;
    void *result = NULL;
    if (pthread_create(&thread, NULL, worker, allocation) ||
        pthread_join(thread, &result) || result != allocation) return 4;
    free(allocation);
    state = 2;
    return 0;
}
