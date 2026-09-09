/* Link exclusively against the candidate ADVAPI32 import library and exercise
 * one imported function on Windows. No registry or filesystem writes. */
__declspec(dllimport) int __stdcall GetUserNameA(char *buffer, unsigned long *size);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(unsigned int code);

void mainCRTStartup(void) {
    char buffer[257];
    unsigned long size = sizeof(buffer);
    int ok = GetUserNameA(buffer, &size);
    ExitProcess(ok && size > 1 && size <= sizeof(buffer) ? 0 : 1);
}
