package main

import "fmt"

func countPrimes(n int64) int64 {
	composite := make([]bool, n+1)
	var count int64
	for i := int64(2); i <= n; i++ {
		if !composite[i] {
			count++
			for j := i * i; j <= n; j += i {
				composite[j] = true
			}
		}
	}
	return count
}

func main() {
	fmt.Println(countPrimes(50000000))
}
