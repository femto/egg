def fill(m, n, seed):
    for i in range(n * n):
        m[i] = (i * seed + 7) % 100


def main():
    n = 800
    x = [0] * (n * n)
    y = [0] * (n * n)
    fill(x, n, 3)
    fill(y, n, 5)
    z = [0] * (n * n)
    for i in range(n):
        for k in range(n):
            xik = x[i * n + k]
            for j in range(n):
                z[i * n + j] += xik * y[k * n + j]
    total = 0
    for v in z:
        total = (total + v) % 1000000007
    print(total)


main()
