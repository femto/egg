#include <stdio.h>
#include <stdint.h>

static int64_t steps(int64_t n) {
    int64_t s = 0;
    while (n != 1) {
        if (n % 2 == 0) n = n / 2;
        else n = 3 * n + 1;
        s++;
    }
    return s;
}

int main(void) {
    int64_t best = 0, best_n = 0;
    for (int64_t i = 1; i < 3000000; i++) {
        int64_t s = steps(i);
        if (s > best) { best = s; best_n = i; }
    }
    printf("%lld\n%lld\n", (long long)best_n, (long long)best);
    return 0;
}
