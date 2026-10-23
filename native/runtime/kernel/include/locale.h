#define LC_ALL 0
static inline char *setlocale(int c, const char *l) { (void)c; (void)l; return "C"; }
