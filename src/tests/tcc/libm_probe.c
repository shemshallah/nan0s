/* libm_probe.c - differential libm check (guest vs host libm).
 * Values are scaled by 1e6 and rounded so tiny last-bit differences do not
 * mask real errors while the transcript stays byte-comparable. */
#include <stdio.h>
#include <math.h>

static int sc(double x)
{
    return (int)(x * 1000000.0 + (x < 0.0 ? -0.5 : 0.5));
}

int main(void)
{
    double ip, fp = modf(3.25, &ip);
    printf("exp0=%d\n", sc(exp(0.0)));
    printf("exp1=%d\n", sc(exp(1.0)));
    printf("expm2=%d\n", sc(exp(-2.0)));
    printf("log2=%d\n", sc(log(2.0)));
    printf("log10=%d\n", sc(log(10.0)));
    printf("log1000=%d\n", sc(log(1000.0)));
    printf("log2_8=%d\n", sc(log2(8.0)));
    printf("log10_1000=%d\n", sc(log10(1000.0)));
    printf("pow_sqrt2=%d\n", sc(pow(2.0, 0.5)));
    printf("pow_2_10=%d\n", sc(pow(2.0, 10.0)));
    printf("pow_9_half=%d\n", sc(pow(9.0, 0.5)));
    printf("pow_m2_3=%d\n", sc(pow(-2.0, 3.0)));
    printf("pow_2_m2=%d\n", sc(pow(2.0, -2.0)));
    printf("sin_pi6=%d\n", sc(sin(M_PI / 6.0)));
    printf("cos_pi3=%d\n", sc(cos(M_PI / 3.0)));
    printf("tan_pi4=%d\n", sc(tan(M_PI / 4.0)));
    printf("asin_half=%d\n", sc(asin(0.5)));
    printf("acos_half=%d\n", sc(acos(0.5)));
    printf("atan1=%d\n", sc(atan(1.0)));
    printf("atan2_1_m1=%d\n", sc(atan2(1.0, -1.0)));
    printf("sinh1=%d\n", sc(sinh(1.0)));
    printf("cosh1=%d\n", sc(cosh(1.0)));
    printf("tanh1=%d\n", sc(tanh(1.0)));
    printf("round25=%d\n", sc(round(2.5)));
    printf("roundm25=%d\n", sc(round(-2.5)));
    printf("truncm27=%d\n", sc(trunc(-2.7)));
    printf("copysign=%d\n", sc(copysign(3.0, -0.0)));
    printf("modf=%d:%d\n", sc(ip), sc(fp));
    printf("finite=%d:%d\n", isfinite(1.0), isfinite(INFINITY));
    printf("signbit=%d\n", signbit(-0.0) ? 1 : 0);
    printf("LIBM PASS\n");
    return 0;
}
