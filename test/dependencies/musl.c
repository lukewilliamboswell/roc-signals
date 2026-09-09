/* Link against the released libc and startup object, with no implicit libc.
 * Exercise startup, allocation, TLS, threads, sorting, formatting, and stdio.
 */
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static _Thread_local int local = 7;

static void *worker(void *argument) {
    assert(local == 7);
    local = 23;
    return argument;
}

static int compare(const void *left, const void *right) {
    int a = *(const int *)left;
    int b = *(const int *)right;
    return (a > b) - (a < b);
}

int main(int argc, char **argv) {
    assert(argc > 0 && argv[0] && argv[argc] == NULL);
    char *buffer = malloc(128);
    assert(buffer);
    assert(snprintf(buffer, 128, "%s %d", "musl", 42) == 7);
    assert(strcmp(buffer, "musl 42") == 0);
    buffer = realloc(buffer, 256);
    assert(buffer && strcmp(buffer, "musl 42") == 0);
    free(buffer);
    int values[] = {5, 1, 4, 2, 3};
    qsort(values, 5, sizeof(int), compare);
    for (int i = 0; i < 5; ++i) assert(values[i] == i + 1);
    pthread_t thread;
    void *result;
    assert(pthread_create(&thread, NULL, worker, values) == 0);
    assert(pthread_join(thread, &result) == 0);
    assert(result == values && local == 7);
    puts("musl dependency smoke passed");
    return 0;
}
