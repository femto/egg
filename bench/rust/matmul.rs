fn fill(m: &mut [i64], n: i64, seed: i64) {
    for i in 0..n * n {
        m[i as usize] = (i * seed + 7) % 100;
    }
}

fn main() {
    let n: i64 = 800;
    let mut x = vec![0i64; (n * n) as usize];
    let mut y = vec![0i64; (n * n) as usize];
    fill(&mut x, n, 3);
    fill(&mut y, n, 5);
    let mut z = vec![0i64; (n * n) as usize];
    for i in 0..n {
        for k in 0..n {
            let xik = x[(i * n + k) as usize];
            for j in 0..n {
                z[(i * n + j) as usize] += xik * y[(k * n + j) as usize];
            }
        }
    }
    drop(x);
    drop(y);
    let mut sum = 0i64;
    for v in &z {
        sum = (sum + v) % 1_000_000_007;
    }
    println!("{}", sum);
}
