/* Vanta kernel libc: math functions for bare metal (double precision, portable C).
 * Accurate to about 1 ulp for normal arguments; good enough for games, graphics and calculators. */
#include <math.h>
#include <stdint.h>
#include <string.h>

static inline uint64_t bits_of(double x) { uint64_t b; memcpy(&b, &x, 8); return b; }
static inline double from_bits(uint64_t b) { double x; memcpy(&x, &b, 8); return x; }

double fabs(double x) { return from_bits(bits_of(x) & ~(1ULL << 63)); }
double copysign(double a, double b) { return from_bits((bits_of(a) & ~(1ULL << 63)) | (bits_of(b) & (1ULL << 63))); }
double sqrt(double x) { return __builtin_sqrt(x); }
double trunc(double x) {
    if (!(fabs(x) < 4503599627370496.0)) return x;   /* already whole (or nan/inf) */
    double t = (double)(int64_t)x;
    return copysign(t, x);
}
double floor(double x) { double t = trunc(x); return (t > x) ? t - 1 : t; }
double ceil(double x) { double t = trunc(x); return (t < x) ? t + 1 : t; }
double round(double x) { double t = trunc(x); if (fabs(x - t) >= 0.5) t += x > 0 ? 1 : -1; return t; }
double rint(double x) {   /* round half to even */
    double t = floor(x), d = x - t;
    if (d > 0.5 || (d == 0.5 && fmod(t, 2.0) != 0)) t += 1;
    return t;
}
double nearbyint(double x) { return rint(x); }
long lround(double x) { return (long)round(x); }
long long llround(double x) { return (long long)round(x); }
double fmin(double a, double b) { return isnan(a) ? b : isnan(b) ? a : a < b ? a : b; }
double fmax(double a, double b) { return isnan(a) ? b : isnan(b) ? a : a > b ? a : b; }

double ldexp(double x, int e) {
    if (x == 0 || isnan(x) || isinf(x)) return x;
    while (e > 1000) { x *= 0x1p1000; e -= 1000; }
    while (e < -1000) { x *= 0x1p-1000; e += 1000; }
    if (e > 1023) { x *= 0x1p1023; e -= 1023; }
    if (e < -1022) { x *= 0x1p-1022; e += 1022; }
    return x * from_bits((uint64_t)(e + 1023) << 52);
}
double frexp(double x, int *e) {
    *e = 0;
    if (x == 0 || isnan(x) || isinf(x)) return x;
    int adj = 0;
    if (fabs(x) < 0x1p-1022) { x *= 0x1p64; adj = -64; }
    uint64_t b = bits_of(x);
    int ex = (int)((b >> 52) & 0x7ff);
    *e = ex - 1022 + adj;
    return from_bits((b & ~(0x7ffULL << 52)) | (1022ULL << 52));
}
double modf(double x, double *ip) { double t = trunc(x); *ip = t; return isinf(x) ? copysign(0, x) : x - t; }

double fmod(double x, double y) {
    if (isnan(x) || isnan(y) || isinf(x) || y == 0) return NAN;
    if (isinf(y)) return x;
    double r = fabs(x), ay = fabs(y);
    while (r >= ay) {             /* each subtraction is exact (Sterbenz), so the result is exact */
        double t = ay;
        while (t * 2 <= r && !isinf(t * 2)) t *= 2;
        r -= t;
    }
    return copysign(r, x);
}

static const double LN2_HI = 6.93147180369123816490e-01, LN2_LO = 1.90821492927058770002e-10;
__attribute__((unused)) static double c_exp(double x) {
    if (isnan(x)) return x;
    if (x > 709.78) return INFINITY;
    if (x < -745.2) return 0;
    double kd = round(x / 0.6931471805599453);
    int k = (int)kd;
    double hi = x - kd * LN2_HI, lo = kd * LN2_LO, r = hi - lo;   /* |r| <= ln2/2 */
    /* fdlibm's method: a rational approximation of e^r that is accurate to well under one ulp */
    double t = r * r;
    double c = r - t * (1.66666666666666019037e-01 + t * (-2.77777777770155933842e-03 + t * (6.61375632143793436117e-05 +
               t * (-1.65339022054652515390e-06 + t * 4.13813679705723846039e-08))));
    double y = 1 - ((lo - (r * c) / (2 - c)) - hi);
    return ldexp(y, k);
}
double expm1(double x) { if (fabs(x) < 1e-5) return x + x * x / 2 + x * x * x / 6; return exp(x) - 1; }
double exp2(double x) { return exp(x * 0.6931471805599453); }

__attribute__((unused)) static double c_log(double x) {
    if (isnan(x) || x < 0) return NAN;
    if (x == 0) return -INFINITY;
    if (isinf(x)) return x;
    int e;
    double m = frexp(x, &e);               /* x = m * 2^e, m in [0.5, 1) */
    if (m < 0.70710678118654752) { m *= 2; e--; }
    double s = (m - 1) / (m + 1), s2 = s * s;   /* |s| <= 0.1716 */
    double term = s, sum = 0;
    for (int i = 1; i <= 41; i += 2) { sum += term / i; term *= s2; }
    return e * LN2_HI + (2 * sum + e * LN2_LO);
}
double log1p(double x) { if (fabs(x) < 1e-5) return x - x * x / 2 + x * x * x / 3; return log(1 + x); }
double log10(double x) {
    double r = log(x) / 2.302585092994045684;
    double n = round(r);                   /* exact powers of ten give exact answers */
    if (fabs(r - n) < 1e-14 && n >= 0 && n <= 22) { double p = 1; for (int i = 0; i < (int)n; i++) p *= 10; if (p == x) return n; }
    return r;
}
double log2(double x) {
    int e; double m = frexp(x, &e);
    if (m == 0.5) return e - 1;           /* exact for powers of two */
    return log(x) / 0.69314718055994530942;
}

static double c_pow(double x, double y) {
    if (y == 0) return 1;
    if (isnan(x) || isnan(y)) return NAN;
    if (y == trunc(y) && fabs(y) < 1e9) {   /* whole powers by repeated squaring: exact when the result fits */
        int64_t n = (int64_t)y;
        int neg = n < 0;
        if (neg) n = -n;
        double r = 1, b = x;
        while (n) { if (n & 1) r *= b; b *= b; n >>= 1; }
        return neg ? 1 / r : r;
    }
    if (x < 0) return NAN;
    if (x == 0) return y > 0 ? 0 : INFINITY;
    if (y == 0.5) return sqrt(x);
    if (y == -0.5) return 1 / sqrt(x);
    if (isinf(y)) return (fabs(x) > 1) == (y > 0) ? INFINITY : 0;
    return exp(y * log(x));
}
double cbrt(double x) {
    if (x == 0 || isnan(x) || isinf(x)) return x;
    double r = copysign(exp(log(fabs(x)) / 3), x);
    r = r - (r * r * r - x) / (3 * r * r);   /* one Newton step */
    return r;
}
double hypot(double x, double y) {
    x = fabs(x); y = fabs(y);
    if (isinf(x) || isinf(y)) return INFINITY;
    double m = x > y ? x : y, n = x > y ? y : x;
    if (m == 0) return 0;
    double r = n / m;
    return m * sqrt(1 + r * r);
}

/* sin/cos: reduce by pi/2 in three parts (Cody-Waite), then series on [-pi/4, pi/4] */
static const double PIO2_1 = 1.57079632673412561417e+00, PIO2_2 = 6.07710050650619224932e-11,
                    PIO2_3 = 2.02226624879595063154e-21;
/* Taylor series summed from the smallest term up (Horner), so rounding errors stay tiny */
static double sin_k(double x) { double x2 = x * x, p = 0; for (int i = 11; i >= 1; i--) p = -x2 / ((2 * i) * (2 * i + 1)) * (1 + p); return x + x * p; }
static double cos_k(double x) {
    double x2 = x * x, p = 0;
    for (int i = 11; i >= 2; i--) p = -x2 / ((2 * i - 1) * (2 * i)) * (1 + p);
    double hz = 0.5 * x2, w = 1 - hz;          /* 1 - x^2/2 - (x^2/2) p, keeping the rounding error of 1 - x^2/2 */
    return w + (((1 - w) - hz) - hz * p);
}
static double reduce(double x, int *q) {
    double k = round(x / 1.57079632679489661923);
    *q = (int)((int64_t)k & 3);
    return ((x - k * PIO2_1) - k * PIO2_2) - k * PIO2_3;
}
static double c_sin(double x) {
    if (isnan(x) || isinf(x)) return NAN;
    int q; double r = reduce(x, &q);
    switch (q) { case 0: return sin_k(r); case 1: return cos_k(r); case 2: return -sin_k(r); default: return -cos_k(r); }
}
static double c_cos(double x) {
    if (isnan(x) || isinf(x)) return NAN;
    int q; double r = reduce(x, &q);
    switch (q) { case 0: return cos_k(r); case 1: return -sin_k(r); case 2: return -cos_k(r); default: return sin_k(r); }
}
static double c_tan(double x) { return sin(x) / cos(x); }

double atan(double x) {
    if (isnan(x)) return x;
    int neg = x < 0; if (neg) x = -x;
    int inv = x > 1; if (inv) x = 1 / x;
    x = x / (1 + sqrt(1 + x * x));          /* atan(x) = 2 atan(x / (1 + sqrt(1 + x^2))): now x <= 0.4142 */
    x = x / (1 + sqrt(1 + x * x));          /* and again: x <= 0.199 */
    double x2 = x * x, term = x, sum = 0;
    for (int i = 0; i < 16; i++) { sum += term / (2 * i + 1); term *= -x2; }
    double r = 4 * sum;
    if (inv) r = 1.57079632679489661923 - r;
    return neg ? -r : r;
}
static double c_atan2(double y, double x) {
    if (isnan(x) || isnan(y)) return NAN;
    if (x == 0) { if (y == 0) return signbit(x) ? copysign(3.14159265358979323846, y) : copysign(0, y); return y > 0 ? 1.57079632679489661923 : -1.57079632679489661923; }
    double a = atan(fabs(y / x));
    if (isinf(x) && isinf(y)) a = 0.78539816339744830962;
    if (x < 0) a = 3.14159265358979323846 - a;
    return signbit(y) ? -a : a;
}
static double c_asin(double x) { if (x < -1 || x > 1) return NAN; return atan2(x, sqrt((1 - x) * (1 + x))); }
static double c_acos(double x) { if (x < -1 || x > 1) return NAN; return atan2(sqrt((1 - x) * (1 + x)), x); }
double sinh(double x) { if (fabs(x) < 1e-5) return x; double e = exp(x); return (e - 1 / e) / 2; }
double cosh(double x) { double e = exp(x); return (e + 1 / e) / 2; }
double tanh(double x) { if (x > 20) return 1; if (x < -20) return -1; double e = exp(2 * x); return (e - 1) / (e + 1); }

/* ---- public entry points: on x86 the x87 unit computes these in 80-bit precision, so after rounding to a double
 * the answers are almost always exactly what a desktop libm gives; elsewhere the portable versions above run. ---- */
#if defined(__x86_64__)
static long double x87_exp2(long double t) {           /* 2^t */
    long double i, f, r;
    __asm__("frndint" : "=t"(i) : "0"(t));     /* nearest whole number */
    f = t - i;
    __asm__("f2xm1" : "=t"(r) : "0"(f));
    r += 1;
    __asm__("fscale" : "=t"(r) : "0"(r), "u"(i));
    return r;
}
static long double x87_ylog2x(long double y, long double x) { long double r; __asm__("fyl2x" : "=t"(r) : "0"(x), "u"(y) : "st(1)"); return r; }
double exp(double x) {
    if (isnan(x)) return x;
    if (x > 709.79) return INFINITY;
    if (x < -745.2) return 0;
    return (double)x87_exp2((long double)x * 1.44269504088896340735992468100189214L);
}
double log(double x) {
    if (isnan(x) || x < 0) return NAN;
    if (x == 0) return -INFINITY;
    if (isinf(x)) return x;
    return (double)x87_ylog2x(0.693147180559945309417232121458176568L, x);
}
double pow(double x, double y) {
    if (y == 0) return 1;
    if (isnan(x) || isnan(y)) return NAN;
    if (y == trunc(y) && fabs(y) < 1e9) return c_pow(x, y);
    if (x < 0) return NAN;
    if (x == 0) return y > 0 ? 0 : INFINITY;
    if (y == 0.5) return sqrt(x);
    if (isinf(y)) return (fabs(x) > 1) == (y > 0) ? INFINITY : 0;
    long double t = x87_ylog2x(y, x);
    if (t > 1024) return INFINITY;
    if (t < -1080) return 0;
    return (double)x87_exp2(t);
}
static int x87_ok(double x) { return fabs(x) < 1e15; }
double sin(double x) { if (!x87_ok(x)) return c_sin(x); long double r; __asm__("fsin" : "=t"(r) : "0"((long double)x)); return (double)r; }
double cos(double x) { if (!x87_ok(x)) return c_cos(x); long double r; __asm__("fcos" : "=t"(r) : "0"((long double)x)); return (double)r; }
double tan(double x) {
    if (!x87_ok(x)) return c_tan(x);
    long double s, c;
    __asm__("fsincos" : "=t"(c), "=u"(s) : "0"((long double)x));
    return (double)(s / c);
}
double atan2(double y, double x) {
    if (isnan(x) || isnan(y) || isinf(x) || isinf(y) || x == 0) return c_atan2(y, x);
    long double r; __asm__("fpatan" : "=t"(r) : "0"((long double)x), "u"((long double)y) : "st(1)");
    return (double)r;
}
static long double x87_atan2(long double y, long double x) { long double r; __asm__("fpatan" : "=t"(r) : "0"(x), "u"(y) : "st(1)"); return r; }
static long double x87_sqrt(long double x) { long double r; __asm__("fsqrt" : "=t"(r) : "0"(x)); return r; }
double asin(double x) { if (!(x >= -1 && x <= 1)) return NAN; if (fabs(x) == 1) return c_asin(x); return (double)x87_atan2(x, x87_sqrt((1.0L - x) * (1.0L + x))); }
double acos(double x) { if (!(x >= -1 && x <= 1)) return NAN; if (x == -1) return c_acos(x); return (double)x87_atan2(x87_sqrt((1.0L - x) * (1.0L + x)), x); }
#else
double asin(double x) { return c_asin(x); }
double acos(double x) { return c_acos(x); }
double exp(double x) { return c_exp(x); }
double log(double x) { return c_log(x); }
double pow(double x, double y) { return c_pow(x, y); }
double sin(double x) { return c_sin(x); }
double cos(double x) { return c_cos(x); }
double tan(double x) { return c_tan(x); }
double atan2(double y, double x) { return c_atan2(y, x); }
#endif

float sqrtf(float x) { return __builtin_sqrtf(x); }
float fabsf(float x) { return x < 0 ? -x : x; }
float floorf(float x) { return (float)floor(x); }
float sinf(float x) { return (float)sin(x); }
float cosf(float x) { return (float)cos(x); }
