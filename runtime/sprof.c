// Sampling profiler (Windows; tests). ODYSSEY_SPROF=<from>:<to> - between those presented frames a thread of its own
// stops every other thread of the process about once a millisecond, reads where it is and lets it go on; then
// build/sprof.txt lists where the time went: guest functions of the game code library (by their guest address, the
// symbols' names: ../ghidra/main_syms.txt) and places in the runtime / system modules (module + offset: addr2line
// -f -e build-test/OdysseyRecomp.exe <0x140000000 + offset> for the exe), per thread and in all.
// Unlike fnprof (call counts) it says what costs time: a frame the game thread can't finish in 16.7 ms.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gamelib.h"
#include "rt.h"

void sprof_frame(uint64_t frame);

#ifndef _WIN32
void sprof_frame(uint64_t frame) { (void)frame; }
#else
#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <timeapi.h>

#define MAXT 128
#define NSLOT (1 << 16)
typedef struct { uint64_t key; uint32_t tid; uint32_t n; } Slot;  // key: a guest function's address | 1ull << 63, or a host rip
static Slot slots[NSLOT];
static volatile LONG running;
static uint64_t g_samples;
static struct { uint32_t tid; uint64_t n, in_game; } threads[MAXT];
static int nthreads;

// the game code's functions by host address: binary search for the one a rip is in
typedef struct { uintptr_t host; uint64_t guest; } FnAt;
static FnAt *fns;
static size_t nfns;
static uintptr_t lib_lo, lib_hi, exe_lo, exe_hi;
static int fn_cmp(const void *a, const void *b) {
    uintptr_t x = ((const FnAt *)a)->host, y = ((const FnAt *)b)->host;
    return x < y ? -1 : x > y;
}
static void fns_build(void) {
    const GameLibTables *t = gamelib_tables();
    if (!t) return;
    size_t n = 0;
    for (uint32_t m = 0; m < t->nmodules; m++) n += *t->modules[m].count;
    fns = malloc(sizeof *fns * n);
    for (uint32_t m = 0; m < t->nmodules; m++)
        for (uint64_t i = 0; i < *t->modules[m].count; i++)
            fns[nfns++] = (FnAt){(uintptr_t)t->modules[m].fns[i], t->modules[m].addrs[i]};
    qsort(fns, nfns, sizeof *fns, fn_cmp);
    HMODULE h = NULL;
    MODULEINFO mi;
    if (nfns && GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                   (LPCSTR)fns[0].host, &h) && GetModuleInformation(GetCurrentProcess(), h, &mi, sizeof mi))
        lib_lo = (uintptr_t)mi.lpBaseOfDll, lib_hi = lib_lo + mi.SizeOfImage;
    if (GetModuleInformation(GetCurrentProcess(), GetModuleHandleA(NULL), &mi, sizeof mi))
        exe_lo = (uintptr_t)mi.lpBaseOfDll, exe_hi = exe_lo + mi.SizeOfImage;
}

static bool in_ours(uintptr_t rip) { return (rip >= lib_lo && rip < lib_hi) || (rip >= exe_lo && rip < exe_hi); }
static uint64_t key_of(uintptr_t rip) {
    if (rip >= lib_lo && rip < lib_hi && nfns) {
        size_t lo = 0, hi = nfns;
        while (hi - lo > 1) { size_t m = (lo + hi) / 2; if (fns[m].host <= rip) lo = m; else hi = m; }
        if (fns[lo].host <= rip) return fns[lo].guest | 1ull << 63;
    }
    return (uint64_t)rip;
}

static void put(uint64_t key, uint32_t tid) {
    uint32_t h = (uint32_t)((key ^ (uint64_t)tid * 0x9E3779B97F4A7C15ull) * 0xff51afd7ed558ccdull >> 48) & (NSLOT - 1);
    for (int i = 0; i < NSLOT; i++, h = (h + 1) & (NSLOT - 1)) {
        if (slots[h].n && slots[h].key == key && slots[h].tid == tid) { slots[h].n++; return; }
        if (!slots[h].n) { slots[h].key = key, slots[h].tid = tid, slots[h].n = 1; return; }
    }
}

static DWORD WINAPI sampler(LPVOID arg) {
    (void)arg;
    DWORD self = GetCurrentThreadId(), pid = GetCurrentProcessId();
    HANDLE hs[MAXT];
    DWORD ids[MAXT];
    int n = 0;
    uint64_t round = 0;
    timeBeginPeriod(1);
    while (running) {
        if (round++ % 500 == 0) {  // (the thread list now and then: the game starts and ends threads)
            for (int i = 0; i < n; i++) CloseHandle(hs[i]);
            n = 0;
            HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
            THREADENTRY32 te = {.dwSize = sizeof te};
            for (BOOL ok = Thread32First(snap, &te); ok && n < MAXT; ok = Thread32Next(snap, &te)) {
                if (te.th32OwnerProcessID != pid || te.th32ThreadID == self) continue;
                HANDLE h = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, te.th32ThreadID);
                if (h) hs[n] = h, ids[n++] = te.th32ThreadID;
            }
            CloseHandle(snap);
        }
        for (int i = 0; i < n; i++) {
            CONTEXT c = {.ContextFlags = CONTEXT_FULL};
            if (SuspendThread(hs[i]) == (DWORD)-1) continue;
            BOOL got = GetThreadContext(hs[i], &c);
            // in a system module (a wait, a lock): the first caller in the runtime or the game code, while the thread
            // is stopped (its stack must not change under the unwind)
            uintptr_t rip = (uintptr_t)c.Rip;
            for (int depth = 0; got && depth < 24 && !in_ours(rip); depth++) {
                DWORD64 base = 0;
                PRUNTIME_FUNCTION fe = RtlLookupFunctionEntry(c.Rip, &base, NULL);
                if (!fe) {  // (a leaf: its return address is on top of the stack)
                    c.Rip = *(DWORD64 *)(uintptr_t)c.Rsp;
                    c.Rsp += 8;
                } else {
                    PVOID hd = NULL;
                    DWORD64 est = 0;
                    RtlVirtualUnwind(UNW_FLAG_NHANDLER, base, c.Rip, fe, &c, &hd, &est, NULL);
                }
                if (!c.Rip) break;
                if (in_ours((uintptr_t)c.Rip)) rip = (uintptr_t)c.Rip | 1;  // (bit 0: reached through a system call)
            }
            ResumeThread(hs[i]);
            if (!got) continue;
            uint64_t k = key_of(rip & ~(uintptr_t)1) | (rip & 1 ? 1ull << 62 : 0);
            put(k, ids[i]);
            int t = 0;
            while (t < nthreads && threads[t].tid != ids[i]) t++;
            if (t == nthreads && nthreads < MAXT) threads[nthreads].tid = ids[i], nthreads++;
            if (t < nthreads) { threads[t].n++; if (k >> 63 && !(k >> 62 & 1)) threads[t].in_game++; }
        }
        g_samples++;
        Sleep(1);
    }
    for (int i = 0; i < n; i++) CloseHandle(hs[i]);
    timeEndPeriod(1);
    return 0;
}

static int slot_cmp(const void *a, const void *b) {
    uint32_t x = ((const Slot *)a)->n, y = ((const Slot *)b)->n;
    return x < y ? 1 : x > y ? -1 : 0;
}
static void where(uint64_t key, char *out, size_t cap) {
    const char *via = key >> 62 & 1 ? "(waiting) " : "";
    key &= ~(1ull << 62);
    if (key >> 63) { snprintf(out, cap, "%sgame %llx", via, (unsigned long long)(key & ~(1ull << 63))); return; }
    HMODULE h = NULL;
    char name[MAX_PATH] = "?";
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)(uintptr_t)key, &h)) {
        GetModuleFileNameA(h, name, sizeof name);
        const char *s = strrchr(name, '\\');
        snprintf(out, cap, "%s%s+%llx", via, s ? s + 1 : name, (unsigned long long)(key - (uintptr_t)h));
    } else snprintf(out, cap, "? %llx", (unsigned long long)key);
}

static void report(long from, long to) {
    const char *path = getenv("ODYSSEY_SPROF_OUT") ? getenv("ODYSSEY_SPROF_OUT") : "build/sprof.txt";
    FILE *f = fopen(path, "w");
    if (!f) return;
    fprintf(f, "frames %ld-%ld, %llu sampling rounds\n\nthreads (samples, in game code):\n", from, to, (unsigned long long)g_samples);
    for (int t = 0; t < nthreads; t++) {
        wchar_t *desc = NULL;
        char dn[128] = "";
        HANDLE h = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, threads[t].tid);
        typedef HRESULT(WINAPI * GTD)(HANDLE, PWSTR *);
        GTD gtd = (GTD)(void *)GetProcAddress(GetModuleHandleA("kernel32.dll"), "GetThreadDescription");
        if (h && gtd && SUCCEEDED(gtd(h, &desc)) && desc) { WideCharToMultiByte(CP_UTF8, 0, desc, -1, dn, sizeof dn, NULL, NULL); LocalFree(desc); }
        if (h) CloseHandle(h);
        if (threads[t].n) fprintf(f, "  tid %u %-24s %llu  %llu\n", threads[t].tid, dn, (unsigned long long)threads[t].n, (unsigned long long)threads[t].in_game);
    }
    Slot *v = malloc(sizeof slots);
    int n = 0;
    for (int i = 0; i < NSLOT; i++) if (slots[i].n) v[n++] = slots[i];
    qsort(v, n, sizeof *v, slot_cmp);
    fprintf(f, "\nhottest (samples, thread, where):\n");
    for (int i = 0; i < n && i < 300; i++) {
        char w[400];
        where(v[i].key, w, sizeof w);
        fprintf(f, "%6u  tid %-6u %s\n", v[i].n, v[i].tid, w);
    }
    free(v);
    fclose(f);
    LOG("[sprof] written %s (frames %ld-%ld)\n", path, from, to);
}

void sprof_frame(uint64_t frame) {
    static long from = -2, to;
    static HANDLE th;
    if (from == -2) {
        from = -1;
        const char *e = getenv("ODYSSEY_SPROF");
        if (e && sscanf(e, "%ld:%ld", &from, &to) != 2) from = -1;
    }
    if (from < 0) return;
    if ((long)frame == from) {
        fns_build();
        running = 1;
        th = CreateThread(NULL, 0, sampler, NULL, 0, NULL);
        LOG("[sprof] on at frame %llu (%zu game functions)\n", (unsigned long long)frame, nfns);
    }
    if ((long)frame == to && th) {
        running = 0;
        WaitForSingleObject(th, INFINITE);
        CloseHandle(th);
        th = NULL;
        report(from, to);
        from = -1;
    }
}
#endif
