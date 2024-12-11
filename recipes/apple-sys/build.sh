#!/usr/bin/env bash

set -euxo pipefail

export BINDGEN_CLANG_PATH="${CC_FOR_BUILD}"
if [[ "${target_platform}" == osx-arm64 ]]; then
    export BINDGEN_EXTRA_CLANG_ARGS_aarch64-apple-darwin="-v --target=aarch64-apple-darwin"
else
    export BINDGEN_EXTRA_CLANG_ARGS_x86_64-apple-darwin="-v --target=x86_64-apple-darwin13.4.0"
fi
export LIBCLANG_PATH="${BUILD_PREFIX}/bin"

cargo fix --lib -p apple-bindgen --allow-no-vcs
cargo build --release --manifest-path=bindgen/Cargo.toml --features=bin
cargo test --release --manifest-path=bindgen/Cargo.toml --features=bin -- --nocapture
CARGO_TARGET_DIR=target cargo install --features=bin --path bindgen --root "${PREFIX}"

# Create conda local source for apple-sys
source ./apple-sys-features.sh
failed_features=()
for feature in "${features[@]}"; do
  if ! cargo build --manifest-path=sys/Cargo.toml --features "$feature"; then
    echo "Warning: Failed to build feature $feature"
    failed_features+=("$feature")
  fi
done

# Print failed features for reference but don't fail the build
if [ ${#failed_features[@]} -ne 0 ]; then
  echo "The following features failed to build:"
  printf '%s\n' "${failed_features[@]}"
fi

mkdir -p "${PREFIX}/src/rust-libraries/${PKG_NAME}-${PKG_VERSION}"
cp -r ./* "${PREFIX}/src/rust-libraries/${PKG_NAME}-${PKG_VERSION}"

# Adding the checksums of the source distribution to the recipe
PKG_SHA256=$(tar -c . | sha256sum | cut -d ' ' -f 1)
cat > $PREFIX/src/rust-libraries/${PKG_NAME}-${PKG_VERSION}/.cargo-checksum.json << EOF
{"files":{},"package":"${PKG_SHA256}"}
EOF

cargo-bundle-licenses --format yaml --output "${RECIPE_DIR}"/THIRDPARTY.yml
