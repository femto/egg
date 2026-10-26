def count_primes(n)
  composite = Array.new(n + 1, false)
  count = 0
  (2..n).each do |i|
    next if composite[i]
    count += 1
    (i * i).step(n, i) { |j| composite[j] = true }
  end
  count
end

puts count_primes(50_000_000)
