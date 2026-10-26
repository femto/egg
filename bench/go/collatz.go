package main

import "fmt"

func steps(n int64) int64 {
	var s int64
	for n != 1 {
		if n%2 == 0 {
			n = n / 2
		} else {
			n = 3*n + 1
		}
		s++
	}
	return s
}

func main() {
	var best, bestN int64
	for i := int64(1); i < 3000000; i++ {
		s := steps(i)
		if s > best {
			best = s
			bestN = i
		}
	}
	fmt.Println(bestN)
	fmt.Println(best)
}
