/* A C library for the link tests: test/run.rb builds it into liblinktest.a. */
#include <stdint.h>

int64_t lt_mix(int64_t a, int64_t b) { return a * 10 + b; }

/* Structs by value, for test/link/structs.egg's extern structs. */
typedef struct { int64_t a, b; } lt_pair;
typedef struct { int64_t a, b, c; int32_t d[2]; } lt_big;
typedef struct { uint8_t tag; lt_pair p; double w; } lt_nest;

lt_pair lt_swap(lt_pair p) { lt_pair r = { p.b, p.a }; return r; }
int64_t lt_big_sum(lt_big b) { return b.a + b.b + b.c + b.d[0] + b.d[1]; }
lt_big lt_big_make(int64_t x) { lt_big b = { x, x * 2, x * 3, { 1, 2 } }; return b; }
double lt_nest_sum(lt_nest n) { return n.tag + n.p.a + n.p.b + n.w; }
void lt_nest_fill(lt_nest *n) { n->tag = 7; n->p.a = 8; n->p.b = 9; n->w = 0.25; }
int64_t lt_apply(int64_t (*f)(lt_big), int64_t x) { return f(lt_big_make(x)); }
