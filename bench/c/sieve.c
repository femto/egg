#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>

static int64_t count_primes(int64_t n) {
    bool *composite = calloc((size_t)n + 1, sizeof(bool));
    int64_t count = 0;
    for (int64_t i = 2; i <= n; i++) {
        if (!composite[i]) {
            count++;
            for (int64_t j = i * i; j <= n; j += i) composite[j] = true;
        }
    }
    free(composite);
    return count;
}

int main(void) {
    printf("%lld\n", (long long)count_primes(50000000));
    return 0;
}
