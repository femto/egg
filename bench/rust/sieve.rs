fn count_primes(n: usize) -> i64 {
    let mut composite = vec![false; n + 1];
    let mut count = 0;
    let mut i = 2;
    while i <= n {
        if !composite[i] {
            count += 1;
            // u64, so i * i cannot overflow where usize is 32 bits
            let mut j = (i as u64) * (i as u64);
            while j <= n as u64 {
                composite[j as usize] = true;
                j += i as u64;
            }
        }
        i += 1;
    }
    count
}

fn main() {
    println!("{}", count_primes(50_000_000));
}
