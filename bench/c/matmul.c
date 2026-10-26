#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

static void fill(int64_t *m, int64_t n, int64_t seed) {
    for (int64_t i = 0; i < n * n; i++) m[i] = (i * seed + 7) % 100;
}

int main(void) {
    const int64_t n = 800;
    int64_t *x = malloc(n * n * sizeof(int64_t));
    int64_t *y = malloc(n * n * sizeof(int64_t));
    int64_t *z = calloc(n * n, sizeof(int64_t));
    fill(x, n, 3);
    fill(y, n, 5);
    for (int64_t i = 0; i < n; i++)
        for (int64_t k = 0; k < n; k++) {
            int64_t xik = x[i * n + k];
            for (int64_t j = 0; j < n; j++) z[i * n + j] += xik * y[k * n + j];
        }
    free(x);
    free(y);
    int64_t sum = 0;
    for (int64_t i = 0; i < n * n; i++) sum = (sum + z[i]) % 1000000007;
    free(z);
    printf("%lld\n", (long long)sum);
    return 0;
}
