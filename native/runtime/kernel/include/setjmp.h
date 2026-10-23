#ifndef _KSETJMP_H
#define _KSETJMP_H
#if defined(__x86_64__)
typedef long jmp_buf[8];          /* rbx rbp r12 r13 r14 r15 rsp rip */
#elif defined(__aarch64__)
typedef long jmp_buf[22];         /* x19-x30, sp, d8-d15 */
#else
#error "the Vanta kernel runtime supports x86_64 and arm64"
#endif
__attribute__((returns_twice)) int setjmp(jmp_buf env);
_Noreturn void longjmp(jmp_buf env, int val);
#define _setjmp setjmp
#define _longjmp longjmp
#endif
