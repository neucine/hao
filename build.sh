#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$repo_root"
cyna_revision=623d2853e2fa397bc6fcf38cfb9288ef8011c739
cyna_source=${HAO_CYNA_SOURCE:-"$repo_root/.deps/cyna-source"}
if ! git -C "$cyna_source" rev-parse --git-dir >/dev/null 2>&1; then
    git clone --quiet https://github.com/neucine/cyna.git "$cyna_source"
    git -C "$cyna_source" checkout --quiet --detach "$cyna_revision"
fi
actual_revision=$(git -C "$cyna_source" rev-parse HEAD)
if [ "$actual_revision" != "$cyna_revision" ]; then
    if [ -n "${HAO_CYNA_SOURCE:-}" ]; then
        echo "Hao requires Cyna source $cyna_revision; found $actual_revision" >&2
        exit 1
    fi
    git -C "$cyna_source" config remote.origin.fetch \
        '+refs/heads/*:refs/remotes/origin/*'
    git -C "$cyna_source" fetch --quiet --tags origin
    git -C "$cyna_source" checkout --quiet --detach "$cyna_revision"
fi
zig_libs_revision=a91b58271be94a4e402a856403fe0fa83add1709
zig_libs_source="$(dirname "$cyna_source")/zig-libs"
if ! git -C "$zig_libs_source" rev-parse --git-dir >/dev/null 2>&1; then
    git clone --quiet https://github.com/neucine/zig-libs.git "$zig_libs_source"
    git -C "$zig_libs_source" checkout --quiet --detach "$zig_libs_revision"
fi
actual_zig_libs=$(git -C "$zig_libs_source" rev-parse HEAD)
if [ "$actual_zig_libs" != "$zig_libs_revision" ]; then
    echo "Hao requires zig-libs $zig_libs_revision; found $actual_zig_libs" >&2
    exit 1
fi
if [ "$(zig version)" != '0.17.0' ]; then
    echo 'Hao requires Zig 0.17.0 to build its pinned Cyna compiler' >&2
    exit 1
fi
(cd "$cyna_source" && zig build)
cyna_bin="$cyna_source/zig-out/bin/cyna"
sh build_deps.sh
"$cyna_bin" build .
"$cyna_bin" build cyna.lib.toml --output build/libhao-cyna-embed.a
sh tools/prepare_std_modules.sh
