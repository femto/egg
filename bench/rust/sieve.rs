fn count_primes(n: usize) -> i64 {
    let mut composite = vec![false; n + 1];
    let mut count = 0;
    let mut i = 2;
    while i <= n {
        if !composite[i] {
            count += 1;
            let mut j = i * i;
            while j <= n {
                composite[j] = true;
                j += i;
            }
        }
        i += 1;
    }
    count
}

fn main() {
    println!("{}", count_primes(50_000_000));
}
