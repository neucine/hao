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

The release workflow verifies the version, builds optimized CLI archives on
Linux and macOS, and publishes a source archive for Zig embedders. CLI archives
contain the executable, addon headers, public TypeScript declarations, and
embedding documentation. Every archive has a matching `.sha256` file.

## Embedding From A Release

The source archive is the release package for Zig embedders. Download it and
add it as a local package dependency, or use the archive URL with `zig fetch`:

```bash
zig fetch --save \
  https://github.com/neucine/hao/releases/download/v0.1.1/hao-0.1.1-source.tar.gz
```

Then import the `hao` module from the fetched dependency in the embedder's
`build.zig`. The archive includes `build.zig`, `build.zig.zon`, `src/`,
`include/`, `types/`, and the embedding documentation. Its dependencies are
resolved by Zig from the hashes recorded in `build.zig.zon`.

A binary runtime library is not published yet. That will require the stable C
runtime embedding ABI and an exported runtime entry point; `include/addon.h`
currently defines the addon ABI only.
