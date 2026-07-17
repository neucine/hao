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

The release workflow verifies the version, builds optimized binaries on Linux
and macOS, and publishes archives containing the CLI, addon headers, and
embedding documentation. GitHub also provides the tagged source archive.

The first release is intentionally a CLI and source-level embedding release.
Language package registries and a stable runtime embedding ABI can be added
once those interfaces are ready.
