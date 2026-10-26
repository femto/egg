def steps(n)
  s = 0
  while n != 1
    n = n.even? ? n / 2 : 3 * n + 1
    s += 1
  end
  s
end

best = 0
best_n = 0
(1...3_000_000).each do |i|
  s = steps(i)
  if s > best
    best = s
    best_n = i
  end
end
puts best_n
puts best
