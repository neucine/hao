import { describe, test, expect } from 'std:test'

function fibonacci(n: number): number {
  if (n <= 1) return n
  let a = 0
  let b = 1
  for (let i = 2; i <= n; i++) {
    const temp = b
    b = a + b
    a = temp
  }
  return b
}

function isPrime(n: number): boolean {
  if (n <= 1) return false
  for (let i = 2; i * i <= n; i++) {
    if (n % i === 0) return false
  }
  return true
}

describe('runtime math', () => {
  test('computes fibonacci values', () => {
    expect([fibonacci(0), fibonacci(1), fibonacci(2), fibonacci(5), fibonacci(9)]).toEqual([0, 1, 1, 5, 34])
  })

  test('finds primes up to 30', () => {
    const primes: number[] = []
    for (let i = 2; i <= 30; i++) {
      if (isPrime(i)) primes.push(i)
    }
    expect(primes).toEqual([2, 3, 5, 7, 11, 13, 17, 19, 23, 29])
  })
})
