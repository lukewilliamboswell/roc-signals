#include <atomic>
#include <climits>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <malloc.h>
#include <thread>

extern "C" int check_rust_unwind(void);
extern "C" int checked_add(int, int);

extern "C" void *roc_alloc(size_t length, size_t alignment) {
    return _aligned_malloc(length == 0 ? 1 : length, alignment);
}
extern "C" void roc_dealloc(void *ptr, size_t) { _aligned_free(ptr); }
extern "C" void *roc_realloc(void *ptr, size_t new_length, size_t alignment) {
    return _aligned_realloc(ptr, new_length == 0 ? 1 : new_length, alignment);
}
static void roc_message(const unsigned char *bytes, size_t len) {
    std::fwrite(bytes, 1, len, stderr);
    std::fputc('\n', stderr);
}
extern "C" void roc_dbg(const unsigned char *bytes, size_t len) { roc_message(bytes, len); }
extern "C" void roc_expect_failed(const unsigned char *bytes, size_t len) { roc_message(bytes, len); }
extern "C" void roc_crashed(const unsigned char *bytes, size_t len) {
    roc_message(bytes, len);
    std::abort();
}

static std::atomic<int> thread_drops{0};
static int exception_drops;
static int exit_callback;
struct ThreadGuard { ~ThreadGuard() { thread_drops.fetch_add(1); } };
struct ExceptionGuard { ~ExceptionGuard() { ++exception_drops; } };
struct ProcessGuard {
    ~ProcessGuard() {
        if (exit_callback != 1 || thread_drops.load() != 2 || exception_drops != 1) std::_Exit(61);
        std::puts("PASS: Windows GNU runtime teardown");
    }
};
static ProcessGuard process_guard;
static void worker() { thread_local ThreadGuard guard; (void)guard; }
int main(int argc, char **) {
    if (argc > 1) return checked_add(INT_MAX, 1);
    if (checked_add(1, 2) != 3) return 1;
    void *memory = std::malloc(128);
    if (!memory) return 2;
    std::free(memory);
    std::thread first(worker), second(worker);
    first.join();
    second.join();
    try { ExceptionGuard guard; throw 42; }
    catch (int value) { if (value != 42) return 3; }
    if (check_rust_unwind() || thread_drops.load() != 2 || exception_drops != 1) return 4;
    if (std::atexit([] { exit_callback = 1; })) return 5;
    std::puts("PASS: Windows GNU runtime startup threads C++ and Rust unwinding");
    return 0;
}
