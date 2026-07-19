<p align="center">
  <img src="assets/brand/hao-horizontal.png" alt="Hao JS" width="360">
</p>

# Hao JS

Hao JS is an embeddable JavaScript and TypeScript runtime for native
projects.

It is meant for projects that want to run JS/TS inside a native host, expose a
few first-party modules, and keep the host language close to the script world.
Hao owns the runtime layer: loading modules, running async work, registering
native bindings, and giving scripts a stable `std:` module namespace.

## Modules

Hao reserves `std:` for runtime modules.

Current modules include:

- `std:runtime`
- `std:fs`
- `std:process`
- `std:http`
- `std:ffi`
- `std:telemetry`
- `std:util`
- `std:test`
- `std:plot`

Host projects should use their own prefixes, such as `affon:` or `myapp:`, for
their product modules.

## Third-Party Packages

Hao loads third-party packages from `node_modules` using package manifests. A
package must include `package.json`, declare `"type": "module"`, and expose
entry points through `exports` or `main`.

```json
{
  "type": "module",
  "exports": {
    ".": "./index.ts",
    "./native": "./native.dylib"
  }
}
```

CommonJS packages and unexported package subpaths are rejected by the module
loader.

## Guides

- [Embedding Hao](docs/embedding.md)
- [Native Addons](docs/addons.md)
- [Telemetry](docs/telemetry.md)
- [Releasing Hao](docs/releasing.md)
- [TODO](docs/TODO.md)

## Try It

```bash
hao path/to/main.ts
hao --version
```

Run tests:

```bash
hao test test/e2e/runtime
```

## Development

Build the local CLI from source:

```bash
zig build
./zig-out/bin/hao path/to/main.ts
```
