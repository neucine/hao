import { describe, test, expect } from 'hao:test'

interface Point {
  x: number
  y: number
}

type Vector = [number, number, number]

function distance(a: Point, b: Point): number {
  return Math.sqrt((b.x - a.x) ** 2 + (b.y - a.y) ** 2)
}

describe('runtime types', () => {
  test('strips interface and type syntax correctly', () => {
    const origin: Point = { x: 0, y: 0 }
    const target: Point = { x: 3, y: 4 }

    expect(distance(origin, target)).toBe(5)

    const vec: Vector = [1, 2, 3]
    expect(vec).toEqual([1, 2, 3])
  })
})
