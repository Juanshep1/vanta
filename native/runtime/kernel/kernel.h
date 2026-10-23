/* Vanta kernel: what the freestanding pieces (libc, memory, drivers, builtins) share.
 *
 * Files in native/runtime/kernel/:
 *   boot_x86_64.S   Multiboot header, 32-bit entry, switch to 64-bit long mode, interrupt stubs, setjmp/longjmp
 *   boot_arm64.S    entry for QEMU's arm64 'virt' board
 *   link_*.ld       where everything goes in memory
 *   kmem.c          physical page allocator + malloc/free (the heap Vanta's values live in)
 *   libc.c kmath.c  the small C library the Vanta runtime needs
 *   kernel.c        boot (kmain), console (VGA text, framebuffer, serial), interrupts, timer, keyboard,
 *                   the ram file system, and every kernel builtin (the `kernel_table`)
 */
#ifndef VANTA_KERNEL_H
#define VANTA_KERNEL_H
#include <stdint.h>
#include <stddef.h>

/* console */
void kcon_write(const char *s, size_t n);
int kcon_read_line(char *buf, int max);       /* an edited line of keyboard (or serial) input, no newline */
int kkey_getchar(void);
_Noreturn void kpanic(const char *msg);
_Noreturn void kexit(int code);

/* time */
uint64_t kticks_ms(void);                     /* milliseconds since boot */
int64_t kboot_epoch(void);                    /* the real-time clock at boot, seconds since 1970 (UTC) */
void ksleep_ms(uint64_t ms);
uint64_t krandom_seed(void);
int64_t kdays_from_civil(int64_t y, unsigned m, unsigned d);

/* memory */
void kmem_init(uintptr_t kernel_end);
void kmem_add_region(uint64_t base, uint64_t len);   /* usable RAM from the boot loader's memory map */
void kmem_reserve(uint64_t base, uint64_t len);
void kmem_ready(void);
void *kpage_alloc(size_t npages);             /* contiguous, 4 KiB aligned; NULL when out of memory */
void kpage_free(void *p, size_t npages);
typedef struct {
    uint64_t total_bytes, free_bytes, heap_bytes, heap_used_bytes, page_size, total_pages, free_pages, allocations;
} KMemInfo;
void kmem_info(KMemInfo *out);

/* port I/O and CPU (x86) */
#if defined(__x86_64__)
static inline void outb(uint16_t p, uint8_t v) { __asm__ volatile("outb %0, %1" ::"a"(v), "Nd"(p)); }
static inline void outw(uint16_t p, uint16_t v) { __asm__ volatile("outw %0, %1" ::"a"(v), "Nd"(p)); }
static inline void outl(uint16_t p, uint32_t v) { __asm__ volatile("outl %0, %1" ::"a"(v), "Nd"(p)); }
static inline uint8_t inb(uint16_t p) { uint8_t v; __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(p)); return v; }
static inline uint16_t inw(uint16_t p) { uint16_t v; __asm__ volatile("inw %1, %0" : "=a"(v) : "Nd"(p)); return v; }
static inline uint32_t inl(uint16_t p) { uint32_t v; __asm__ volatile("inl %1, %0" : "=a"(v) : "Nd"(p)); return v; }
static inline void io_wait(void) { outb(0x80, 0); }
#endif
#endif
