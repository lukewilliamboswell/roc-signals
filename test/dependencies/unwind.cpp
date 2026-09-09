#include <stdio.h>
static int destroyed;
struct Guard { ~Guard() { destroyed++; } };
static void inner() { Guard guard; throw 42; }
int main() {
    try { inner(); } catch (int value) {
        if (value == 42 && destroyed == 1) { puts("PASS: C++ exception unwinding"); return 0; }
    }
    return 1;
}
