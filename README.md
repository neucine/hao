# Hao JS

Hao JS is a small embeddable JavaScript and TypeScript runtime for native
projects.

It is meant for projects that want to run JS/TS inside a native host, expose a
few first-party modules, and keep the host language close to the script world.
Hao owns the runtime layer: loading modules, running async work, registering
native bindings, and giving scripts a stable `hao:` module namespace.

## Modules

Hao reserves `hao:` for runtime modules.

Current modules include:

- `hao:runtime`
- `hao:fs`
- `hao:process`
- `hao:http`
- `hao:ffi`
- `hao:util`
- `hao:test`
- `hao:plot`

Host projects should use their own prefixes, such as `affon:` or `myapp:`, for
their product modules.

## Try It

```bash
hao path/to/main.ts
```

Run tests:

```bash
hao test test/e2e/runtime
```

Check TypeScript declarations:

```bash
bun x tsc -p test/types/tsconfig.json --noEmit
```

## Development

Build the local CLI from source:

```bash
zig build
./zig-out/bin/hao path/to/main.ts
```

## Configuration

Hao reads configuration from the environment. It also loads dotenv values before
reading config:

- `.env` in the current working directory is loaded when present.
- `DOTENV=/path/to/file` loads a specific dotenv file.
- Existing environment variables override dotenv values.

Current runtime config:

- `HAO_QJS_STACK_SIZE`
- `HAO_LIBUV_THREADPOOL_SIZE`
- `HAO_NATIVE_STACK_TRACE`
