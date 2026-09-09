/* No C runtime: all calls resolve through the exact candidate DLL archives. */
/* Windows x64 ABI declarations avoid any installed SDK header search. */
typedef unsigned short WCHAR;
typedef unsigned long DWORD;
typedef long LONG;
typedef void *HMODULE;
typedef union { long long QuadPart; } LARGE_INTEGER;
#define NTAPI __stdcall
#define COINIT_MULTITHREADED 0
__declspec(dllimport) DWORD __stdcall GetSystemDirectoryW(WCHAR *, unsigned int);
__declspec(dllimport) HMODULE __stdcall GetModuleHandleW(const WCHAR *);
__declspec(dllimport) DWORD __stdcall GetModuleFileNameW(HMODULE, WCHAR *, DWORD);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(unsigned int);
__declspec(dllimport) long __stdcall CoInitializeEx(void *, DWORD);
__declspec(dllimport) void *__stdcall CoTaskMemAlloc(unsigned long long);
__declspec(dllimport) void __stdcall CoTaskMemFree(void *);
__declspec(dllimport) void __stdcall CoUninitialize(void);

__declspec(dllimport) int u_strlen(const unsigned short *text);
__declspec(dllimport) LONG NTAPI NtQuerySystemTime(LARGE_INTEGER *time);

void mainCRTStartup(void) {
    static const unsigned short text[] = {'r', 'o', 'c', 0};
    static WCHAR module_path[32768];
    static WCHAR system_path[32768];
    LARGE_INTEGER time;
    DWORD length = GetSystemDirectoryW(system_path, 32768);
    HMODULE module = GetModuleHandleW(L"icuuc.dll");
    if (!length || length >= 32768 || !module) ExitProcess(10);
    DWORD module_length = GetModuleFileNameW(module, module_path, 32768);
    if (!module_length || module_length >= 32768 || module_length <= length) ExitProcess(11);
    for (DWORD i = 0; i < length; ++i) {
        WCHAR a = module_path[i], b = system_path[i];
        if (a >= 'A' && a <= 'Z') a += 'a' - 'A';
        if (b >= 'A' && b <= 'Z') b += 'a' - 'A';
        if (a != b) ExitProcess(12);
    }
    if (module_path[length] != '\\') ExitProcess(13);
    if (u_strlen(text) != 3) ExitProcess(14);
    if (NtQuerySystemTime(&time) < 0 || time.QuadPart <= 0) ExitProcess(15);
    if (CoInitializeEx(0, COINIT_MULTITHREADED) < 0) ExitProcess(16);
    void *memory = CoTaskMemAlloc(32);
    if (!memory) ExitProcess(17);
    CoTaskMemFree(memory);
    CoUninitialize();
    ExitProcess(0);
}
