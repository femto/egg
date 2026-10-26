def count_primes(n):
    composite = bytearray(n + 1)
    count = 0
    for i in range(2, n + 1):
        if not composite[i]:
            count += 1
            for j in range(i * i, n + 1, i):
                composite[j] = 1
    return count


print(count_primes(50000000))
