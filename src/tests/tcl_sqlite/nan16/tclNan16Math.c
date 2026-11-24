/*
 * tclNan16Math.c -- remaining double math function absent from the NaN16 libc.
 *
 * The guest libc now provides exp/log/pow and the full trig family
 * (third_party/nan16-libc).  Tcl's BuiltinFuncTable also references hypot,
 * which is implemented here on top of the libc's sqrt.
 */
#include <math.h>

double
hypot(double x, double y)
{
    x = fabs(x);
    y = fabs(y);
    if (x < y) {
	double t = x;
	x = y;
	y = t;
    }
    if (x == 0.0) {
	return 0.0;
    }
    {
	double r = y / x;
	return x * sqrt(1.0 + r * r);
    }
}
