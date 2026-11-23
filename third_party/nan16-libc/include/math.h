#ifndef _MATH_H
#define _MATH_H
#define HUGE_VAL 1.7976931348623157e+308
#define HUGE_VALF 3.40282347e+38F
#define INFINITY (1.0/0.0)
#define NAN (0.0/0.0)
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
int isnan(double);
int isinf(double);
#endif
