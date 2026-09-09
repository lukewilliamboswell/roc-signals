#include <stdio.h>
extern int check_rust_unwind(void);
int main(void) { if (check_rust_unwind()) return 1; puts("PASS: Rust panic caught and destructor executed"); return 0; }
