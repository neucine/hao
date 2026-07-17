# Hao JS

Hao JS is an embeddable JavaScript/TypeScript runtime substrate for native packages.

This repository is being extracted from Affon. The first boundary is intentionally
small: QuickJS lifecycle helpers, TypeScript transform bindings, filesystem and
package resolution, libuv-backed timer/event-loop driving, and a package
registry that lets host applications provide source modules and native modules
without baking Affon module names into the engine.

Host applications register native packages through `hao.Package`, combining
embedded source modules with QuickJS C modules.

The `hao:` namespace is reserved for Hao-owned first-party runtime modules.
Host applications should use their own prefixes, such as `affon:` or `myapp:`,
for product/domain modules.

Current first-party modules:

- `hao:runtime`
- `hao:fs`
- `hao:process` (`getEnv`, `run`)

Run a script:

```bash
zig build
./zig-out/bin/hao path/to/main.ts
```

Check TypeScript declarations:

```bash
bun x tsc -p test/types/tsconfig.json --noEmit
```

Runtime configuration is read from process environment variables after loading
dotenv values. Hao loads `.env` from the current working directory when present,
or the file pointed to by `DOTENV=/path/to/env`. Existing environment variables
win over dotenv values.

Affon remains unchanged during extraction. Once Hao has a stable embedded
runtime API, Affon can switch to consuming Hao as a sibling dependency.
