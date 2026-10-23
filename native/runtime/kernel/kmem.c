/* Vanta kernel memory: a physical page allocator and the heap (malloc/free) on top of it.
 *
 * Pages: one bit per 4 KiB page of the first 4 GiB of physical address space (1 = in use). Everything starts
 * "in use"; the boot loader's memory map frees the usable RAM, then the kernel image, the first megabyte (BIOS,
 * VGA memory) and the boot information are reserved again.
 *
 * Heap: small blocks (up to 4 KiB) come from size classes carved out of 1 MiB arenas taken from the page
 * allocator, and go back on a per-class free list when freed. Big blocks get their own run of pages, which go back
 * to the page allocator when freed. Every block has a 16-byte header so blocks stay 16-byte aligned.
 */
#include "kernel.h"
#include <string.h>

#define PAGE 4096ULL
#define MAX_PAGES (1ULL << 20)                 /* 4 GiB */
static uint64_t bitmap[MAX_PAGES / 64];
static uint64_t total_pages = 0, free_pages = 0, search_hint = 0;

static inline int used(uint64_t p) { return (bitmap[p >> 6] >> (p & 63)) & 1; }
static inline void set_used(uint64_t p) { bitmap[p >> 6] |= 1ULL << (p & 63); }
static inline void set_free(uint64_t p) { bitmap[p >> 6] &= ~(1ULL << (p & 63)); }

void kmem_init(uintptr_t kernel_end) {
    (void)kernel_end;
    memset(bitmap, 0xff, sizeof bitmap);
    total_pages = free_pages = 0;
}
void kmem_add_region(uint64_t base, uint64_t len) {
    uint64_t first = (base + PAGE - 1) / PAGE, last = (base + len) / PAGE;
    if (last > MAX_PAGES) last = MAX_PAGES;
    for (uint64_t p = first; p < last; p++) if (used(p)) { set_free(p); total_pages++; free_pages++; }
}
void kmem_reserve(uint64_t base, uint64_t len) {
    uint64_t first = base / PAGE, last = (base + len + PAGE - 1) / PAGE;
    if (last > MAX_PAGES) last = MAX_PAGES;
    for (uint64_t p = first; p < last; p++) if (!used(p)) { set_used(p); free_pages--; total_pages--; }
}
void kmem_ready(void) { search_hint = 0; }

void *kpage_alloc(size_t n) {
    if (n == 0) n = 1;
    uint64_t run = 0, start = 0;
    for (int pass = 0; pass < 2; pass++) {
        uint64_t from = pass == 0 ? search_hint : 0, to = pass == 0 ? MAX_PAGES : search_hint + n;
        if (to > MAX_PAGES) to = MAX_PAGES;
        run = 0;
        for (uint64_t p = from; p < to; p++) {
            if ((p & 63) == 0 && run == 0 && bitmap[p >> 6] == ~0ULL) { p += 63; continue; }   /* skip full words */
            if (used(p)) { run = 0; continue; }
            if (run == 0) start = p;
            if (++run == n) {
                for (uint64_t q = start; q < start + n; q++) set_used(q);
                free_pages -= n;
                search_hint = start + n;
                return (void *)(uintptr_t)(start * PAGE);
            }
        }
    }
    return NULL;
}
void kpage_free(void *ptr, size_t n) {
    uint64_t p = (uintptr_t)ptr / PAGE;
    for (uint64_t q = p; q < p + n && q < MAX_PAGES; q++) if (used(q)) { set_free(q); free_pages++; }
    if (p < search_hint) search_hint = p;
}

/* ---------------------------------------------------------------- the heap */
typedef struct Hdr { uint32_t magic; uint32_t cls; uint64_t size; } Hdr;   /* size: payload bytes (big: pages) */
#define MAGIC_SMALL 0x56414e54u   /* "VANT" */
#define MAGIC_BIG 0x56424947u
#define MAGIC_FREE 0x46524545u
static const uint32_t CLASS[] = {16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 640, 768,
                                 896, 1024, 1280, 1536, 1792, 2048, 2560, 3072, 4080};
#define NCLASS (sizeof CLASS / sizeof CLASS[0])
static void *free_list[NCLASS];
static char *arena_ptr = NULL, *arena_end = NULL;
static uint64_t heap_bytes = 0, heap_used = 0, nallocs = 0;
#define ARENA (1024 * 1024)

static int class_for(size_t n) {
    for (unsigned i = 0; i < NCLASS; i++) if (n <= CLASS[i]) return (int)i;
    return -1;
}

void *malloc(size_t n) {
    int c = class_for(n);
    if (c < 0) {
        size_t pages = (n + sizeof(Hdr) + PAGE - 1) / PAGE;
        Hdr *h = kpage_alloc(pages);
        if (!h) return NULL;
        h->magic = MAGIC_BIG; h->cls = 0; h->size = pages;
        heap_bytes += pages * PAGE; heap_used += pages * PAGE; nallocs++;
        return h + 1;
    }
    Hdr *h;
    if (free_list[c]) {
        h = (Hdr *)free_list[c] - 1;
        free_list[c] = *(void **)free_list[c];
    } else {
        size_t need = sizeof(Hdr) + CLASS[c];
        if (!arena_ptr || arena_ptr + need > arena_end) {
            char *a = kpage_alloc(ARENA / PAGE);
            if (!a) return NULL;
            arena_ptr = a; arena_end = a + ARENA;
            heap_bytes += ARENA;
        }
        h = (Hdr *)arena_ptr;
        arena_ptr += need;
    }
    h->magic = MAGIC_SMALL; h->cls = (uint32_t)c; h->size = CLASS[c];
    heap_used += CLASS[c] + sizeof(Hdr); nallocs++;
    return h + 1;
}

void free(void *p) {
    if (!p) return;
    Hdr *h = (Hdr *)p - 1;
    if (h->magic == MAGIC_BIG) {
        h->magic = MAGIC_FREE;
        heap_bytes -= h->size * PAGE; heap_used -= h->size * PAGE; nallocs--;
        kpage_free(h, h->size);
        return;
    }
    if (h->magic != MAGIC_SMALL) kpanic("free(): that isn't a heap block (heap corrupted or freed twice)");
    h->magic = MAGIC_FREE;
    heap_used -= CLASS[h->cls] + sizeof(Hdr); nallocs--;
    *(void **)p = free_list[h->cls];
    free_list[h->cls] = p;
}

static size_t capacity(void *p) {
    Hdr *h = (Hdr *)p - 1;
    return h->magic == MAGIC_BIG ? h->size * PAGE - sizeof(Hdr) : CLASS[h->cls];
}

void *calloc(size_t n, size_t size) {
    size_t total = n * size;
    if (size && total / size != n) return NULL;
    void *p = malloc(total);
    if (p) memset(p, 0, total);
    return p;
}

void *realloc(void *p, size_t n) {
    if (!p) return malloc(n);
    if (n == 0) { free(p); return NULL; }
    size_t cap = capacity(p);
    if (n <= cap) return p;
    void *q = malloc(n);
    if (!q) return NULL;
    memcpy(q, p, cap);
    free(p);
    return q;
}

void kmem_info(KMemInfo *o) {
    o->page_size = PAGE;
    o->total_pages = total_pages;
    o->free_pages = free_pages;
    o->total_bytes = total_pages * PAGE;
    o->free_bytes = free_pages * PAGE;
    o->heap_bytes = heap_bytes;
    o->heap_used_bytes = heap_used;
    o->allocations = nallocs;
}
