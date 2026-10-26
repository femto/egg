package main

import "fmt"

func fill(m []int64, n, seed int64) {
	for i := int64(0); i < n*n; i++ {
		m[i] = (i*seed + 7) % 100
	}
}

func main() {
	const n int64 = 800
	x := make([]int64, n*n)
	y := make([]int64, n*n)
	fill(x, n, 3)
	fill(y, n, 5)
	z := make([]int64, n*n)
	for i := int64(0); i < n; i++ {
		for k := int64(0); k < n; k++ {
			xik := x[i*n+k]
			for j := int64(0); j < n; j++ {
				z[i*n+j] += xik * y[k*n+j]
			}
		}
	}
	var sum int64
	for _, v := range z {
		sum = (sum + v) % 1000000007
	}
	fmt.Println(sum)
}
