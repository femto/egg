/* A C library for the link tests: test/run.rb builds it into liblinktest.a. */
#include <stdint.h>

int64_t lt_mix(int64_t a, int64_t b) { return a * 10 + b; }
