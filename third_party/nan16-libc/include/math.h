#ifndef _MATH_H
#define _MATH_H
#define HUGE_VAL 1.7976931348623157e+308
#define HUGE_VALF 3.40282347e+38F
#define INFINITY (1.0/0.0)
#define NAN (0.0/0.0)
#define M_E        2.7182818284590452354
#define M_LOG2E    1.4426950408889634074
#define M_LOG10E   0.43429448190325182765
#define M_LN2      0.69314718055994530942
#define M_LN10     2.30258509299404568402
#define M_PI       3.14159265358979323846
#define M_PI_2     1.57079632679489661923
#define M_PI_4     0.78539816339744830962
#define M_1_PI     0.31830988618379067154
#define M_2_PI     0.63661977236758134308
#define M_2_SQRTPI 1.12837916709551257390
#define M_SQRT2    1.41421356237309504880
#define M_SQRT1_2  0.70710678118654752440
double ldexp(double, int);
long double ldexpl(long double, int);
double frexp(double, int *);
long double frexpl(long double, int *);
double fabs(double);
long double fabsl(long double);
double floor(double);
double ceil(double);
double sqrt(double);
double pow(double, double);
double fmod(double, double);
double trunc(double);
double round(double);
double copysign(double, double);
double exp(double);
double log(double);
double log10(double);
double log2(double);
double sin(double);
double cos(double);
double tan(double);
double asin(double);
double acos(double);
double atan(double);
double atan2(double, double);
double sinh(double);
double cosh(double);
double tanh(double);
double modf(double, double *);
int isnan(double);
int isinf(double);
#define isfinite(x) (!isnan(x) && !isinf(x))
#define signbit(x) ((x) < 0.0 || ((x) == 0.0 && 1.0 / (x) < 0.0))
#endif
