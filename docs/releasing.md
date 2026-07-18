# Releasing Hao

Hao releases are created from version tags. The tag, `build.zig.zon`, and
`src/version.zig` must use the same semantic version.

## Release

1. Update the version in `build.zig.zon` and `src/version.zig`.
2. Run the CI checks locally:

   ```bash
   zig build test
   zig build
   ./zig-out/bin/hao --version
   ```

3. Commit the version change and push `main`.
4. Create and push a tag:

   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```

The release workflow verifies the version and builds Linux and macOS release
assets. Each platform publishes one source-level embedder archive and one
standalone CLI binary. Every release asset has a matching `.sha256` file.

## Embedding From A Release

The platform `.tar.gz` archive is the release package for Zig embedders.
Download it and add it as a local package dependency, or use the archive URL
with `zig fetch`:

```bash
zig fetch --save \
  https://github.com/neucine/hao/releases/download/v0.1.2/hao-0.1.2-linux-x86_64.tar.gz
```

Then import the `hao` module from the fetched dependency in the embedder's
`build.zig`. The archive includes `build.zig`, `build.zig.zon`, `src/`,
`include/`, and `libs/transpiler/`. Its dependencies are resolved by Zig from
the hashes recorded in `build.zig.zon`. The standalone
`hao-<version>-<os>-<arch>` asset is the prebuilt CLI binary for that platform.

The package exposes one native link artifact for source-level embedders:

```zig
const hao = b.dependency("hao", .{ .target = target, .optimize = optimize });

const app = b.addExecutable(.{ .name = "app", .root_module = app_module });
app.root_module.addImport("hao", hao.module("hao"));
app.root_module.linkLibrary(hao.artifact("hao_runtime"));
```

Consumers do not need to link Hao's QuickJS, libuv, or transpiler dependencies
individually.

A binary runtime library is not published yet. That will require the stable C
runtime embedding ABI and an exported runtime entry point; `include/addon.h`
currently defines the addon ABI only.
