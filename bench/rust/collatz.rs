fn steps(mut n: i64) -> i64 {
    let mut s = 0;
    while n != 1 {
        if n % 2 == 0 {
            n /= 2;
        } else {
            n = 3 * n + 1;
        }
        s += 1;
    }
    s
}

fn main() {
    let (mut best, mut best_n) = (0, 0);
    for i in 1..3_000_000 {
        let s = steps(i);
        if s > best {
            best = s;
            best_n = i;
        }
    }
    println!("{}\n{}", best_n, best);
}
