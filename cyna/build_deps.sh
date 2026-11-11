#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
deps="$repo_root/cyna/.deps"
install="$deps/install"
mkdir -p "$deps" "$install/include" "$install/lib"

fetch_source() {
    name=$1
    url=$2
    expected=$3
    archive="$deps/$name.tar.gz"
    source="$deps/$name"
    if [ ! -f "$archive" ]; then
        curl --fail --location --retry 3 --silent --show-error "$url" -o "$archive.tmp"
        mv "$archive.tmp" "$archive"
    fi
    actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
    if [ "$actual" != "$expected" ]; then
        echo "Checksum mismatch for $name: $actual" >&2
        exit 1
    fi
    if [ ! -d "$source" ]; then
        mkdir "$source"
        tar -xzf "$archive" -C "$source" --strip-components=1
    fi
}

fetch_source quickjs \
    https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.13.0.tar.gz \
    13ed1d22cd4b2b693a94a234e752d1ea6a0064434a740031ff90439679257c6c
fetch_source libuv \
    https://dist.libuv.org/dist/v1.51.0/libuv-v1.51.0.tar.gz \
    5f0557b90b1106de71951a3c3931de5e0430d78da1d9a10287ebc7a3f78ef8eb

if ! grep -q 'JS_SetJobContextHooks' "$deps/quickjs/quickjs.h"; then
    patch -d "$deps/quickjs" -p1 < "$repo_root/cyna/patches/quickjs-job-context.patch"
    rm -f "$install/lib/libquickjs.a"
fi

if [ ! -f "$install/lib/libquickjs.a" ]; then
    mkdir -p "$deps/quickjs-objects"
    for source in quickjs libregexp libunicode dtoa; do
        cc -O2 -std=gnu11 -fwrapv -D_GNU_SOURCE '-DCONFIG_VERSION="0.13.0"' \
            -I "$deps/quickjs" -c "$deps/quickjs/$source.c" \
            -o "$deps/quickjs-objects/$source.o"
    done
    ar rcs "$install/lib/libquickjs.a" "$deps/quickjs-objects"/*.o
    cp "$deps/quickjs/quickjs.h" "$install/include/quickjs.h"
    cp "$deps/quickjs/quickjs-libc.h" "$install/include/quickjs-libc.h"
fi

if [ ! -f "$install/lib/libuv.a" ]; then
    cmake -S "$deps/libuv" -B "$deps/libuv-build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$install" \
        -DLIBUV_BUILD_SHARED=OFF -DLIBUV_BUILD_TESTS=OFF -DLIBUV_BUILD_BENCH=OFF
    cmake --build "$deps/libuv-build" --parallel
    cmake --install "$deps/libuv-build"
fi

cargo build --release --locked --manifest-path "$repo_root/libs/transpiler/Cargo.toml"
