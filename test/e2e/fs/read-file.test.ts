import { describe, test, expect } from 'std:test'
import { existsSync, readFileSync, statSync, writeFileSync } from 'std:fs'

describe('fs read-file', () => {
  test('readFileSync reads the current file', () => {
    const content = readFileSync('test/e2e/fs/read-file.test.ts')
    expect(content).toContain("import { existsSync, readFileSync, statSync, writeFileSync } from 'std:fs'")
    expect(content).toContain("describe('fs read-file'")
  })

  test('writeFileSync creates files and statSync reports size', () => {
    const path = '.hao-e2e-fs.txt'
    writeFileSync(path, 'hello from hao')
    expect(existsSync(path)).toBe(true)
    expect(readFileSync(path)).toBe('hello from hao')
    expect(statSync(path).size).toBe(14)
  })
})
