def fill(m, n, seed)
  (n * n).times { |i| m[i] = (i * seed + 7) % 100 }
end

n = 800
x = Array.new(n * n, 0)
y = Array.new(n * n, 0)
fill(x, n, 3)
fill(y, n, 5)
z = Array.new(n * n, 0)
n.times do |i|
  n.times do |k|
    xik = x[i * n + k]
    n.times do |j|
      z[i * n + j] += xik * y[k * n + j]
    end
  end
end
sum = 0
z.each { |v| sum = (sum + v) % 1_000_000_007 }
puts sum
