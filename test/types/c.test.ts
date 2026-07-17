import { c } from 'std:ffi'
import type { CHandle } from 'std:ffi'

const { decl: cdecl } = c

type IsExact<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false
function assertType<T extends true>() {}

const libm = cdecl('m', `
  double sqrt(double x);
`)

const direct = libm.sqrt(16)
assertType<IsExact<typeof direct, number>>()
// @ts-expect-error - sqrt expects a number
libm.sqrt('16')
// @ts-expect-error - sqrt arity is inferred from the declaration
libm.sqrt()
libm.close()

const sqlite = cdecl('sqlite3', `
  typedef struct sqlite3 sqlite3;
  int32_t sqlite3_open(const char* filename, sqlite3** out_db);
  int32_t sqlite3_close(sqlite3* db);
`, {
  handles: {
    sqlite3: { close: 'sqlite3_close' },
  },
  functions: {
    sqlite3_open: {
      returns: { out: 'out_db' },
    },
  },
} as const)

const db = sqlite.sqlite3_open(':memory:')
assertType<IsExact<typeof db, CHandle<'sqlite3'>>>()
// @ts-expect-error - out_db is hidden from the JS call surface
sqlite.sqlite3_open(':memory:', 0)
if (typeof db === 'object' && db !== null) {
  db.close()
}
sqlite.sqlite3_close(db)
// @ts-expect-error - sqlite3_close expects a handle-like pointer, not a string
sqlite.sqlite3_close('not-a-db')
// @ts-expect-error - sqlite3_close takes exactly one visible argument
sqlite.sqlite3_close()

const libc = cdecl('c', `
  void* memcpy(void* dest, const void* src, size_t n);
`, {
  functions: {
    memcpy: {
      buffers: {
        dest: { length: 'n', element: 'u8', direction: 'out' },
        src: { length: 'n', element: 'u8' },
      },
    },
  },
} as const)

const dest = new Uint8Array(4)
const src = new Uint8Array([1, 2, 3, 4])
libc.memcpy(dest, src)
libc.memcpy(new ArrayBuffer(4), src)
// @ts-expect-error - memcpy buffer policy expects typed-array or ArrayBuffer values
libc.memcpy('dest', src)
// @ts-expect-error - u8 buffer policy does not infer Float32Array as the primary typed-array family
libc.memcpy(new Float32Array(1), src)
// @ts-expect-error - hidden length param is not part of the JS signature
libc.memcpy(dest, src, 4)
libc.close()

const floatBufLib = cdecl('vec', `
  float sum_f32(const float* values, size_t len);
`, {
  functions: {
    sum_f32: {
      buffers: {
        values: { length: 'len', element: 'f32' },
      },
    },
  },
} as const)

floatBufLib.sum_f32(new Float32Array([1, 2, 3]))
floatBufLib.sum_f32(new ArrayBuffer(12))
// @ts-expect-error - f32 buffer policy should prefer Float32Array or raw ArrayBuffer
floatBufLib.sum_f32(new Uint8Array(12))
// @ts-expect-error - f32 buffer policy still requires exactly one visible argument
floatBufLib.sum_f32(new Float32Array([1, 2, 3]), 3)

const searched = cdecl('System.B', `
  size_t strlen(const char* s);
`, {
  search: {
    strategy: 'relative-first',
    paths: ['/usr/lib'],
  },
})

searched.strlen('hello')
assertType<IsExact<ReturnType<typeof searched.strlen>, number>>()
// @ts-expect-error - strlen expects a string
searched.strlen(123)
// @ts-expect-error - strlen arity is inferred from the declaration
searched.strlen()
searched.close()

const geom = cdecl('geom', `
  typedef struct {
    double x;
    double y;
  } Point;

  double norm(Point p);
  void translate(Point* p, double dx, double dy);
`)

geom.norm({ x: 3, y: 4 })
// @ts-expect-error - missing struct field
geom.norm({ x: 3 })
// @ts-expect-error - wrong field type
geom.norm({ x: '3', y: 4 })
geom.translate({ x: 1, y: 2 }, 3, 4)
// @ts-expect-error - struct pointer params still require the POD object shape when not passing a raw pointer number
geom.translate({ x: 1 }, 3, 4)

const nestedGeom = cdecl('nested-geom', `
  typedef struct {
    int32_t x;
    int32_t y;
  } Inner;

  typedef struct {
    Inner inner;
    double scale;
  } Outer;

  void mutate(Outer* outer);
`)

nestedGeom.mutate({ inner: { x: 1, y: 2 }, scale: 3 })
// @ts-expect-error - nested POD struct fields still require the full nested object shape
nestedGeom.mutate({ inner: { x: 1 }, scale: 3 })
// @ts-expect-error - nested POD struct fields preserve scalar type expectations
nestedGeom.mutate({ inner: { x: '1', y: 2 }, scale: 3 })

// @ts-expect-error - declarations must be a string
cdecl('sqlite3', 123)

cdecl('sqlite3', 'typedef struct sqlite3 sqlite3;', {
  handles: {
    // @ts-expect-error - handle close symbol must be a string when present
    sqlite3: { close: 123 },
  },
})
