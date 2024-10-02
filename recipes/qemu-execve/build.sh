#!/usr/bin/env bash

set -euxo pipefail

source "${RECIPE_DIR}/helpers/_build_qemu.sh"

# --- Main ---

# Build aarch64 on linux and windows with gcc
if [[ "${build_platform}" == "linux-64" ]] || [[ "${build_platform}" == "win-64" ]]; then
  qemu_arch="aarch64"
  build_qemu \
    ${qemu_arch} \
    "${qemu_arch}-conda-linux-gnu-" \
    "${BUILD_PREFIX}/${qemu_arch}-conda-linux-gnu/sysroot" \
    "${SRC_DIR}/_conda-build-${qemu_arch}" \
    "${SRC_DIR}/_conda-install-${qemu_arch}"
fi

# if [[ "${build_platform}" == "linux-64" ]]; then
#   qemu_arch="ppc64le"
#   sysroot_arch="powerpc64le"
#   build_qemu \
#     ${qemu_arch} \
#     "${sysroot_arch}-conda-linux-gnu-" \
#     "${BUILD_PREFIX}/${sysroot_arch}-conda-linux-gnu/sysroot" \
#     "${SRC_DIR}/_conda-build-${qemu_arch}" \
#     "${SRC_DIR}/_conda-install-${qemu_arch}"
#
#   qemu_arch="win64"
#   sysroot_arch="win64"
#   build_qemu \
#     ${qemu_arch} \
#     "x86_64-w64-mingw32-" \
#     "${BUILD_PREFIX}/x86_64-w64-mingw32-gnu/sysroot" \
#     "${SRC_DIR}/_conda-build-${qemu_arch}" \
#     "${SRC_DIR}/_conda-install-${qemu_arch}"
#
#   qemu_arch="riscv64"
#   sysroot_arch="riscv64"
#   build_qemu \
#     ${qemu_arch} \
#     "${sysroot_arch}-conda-linux-gnu-" \
#     "${BUILD_PREFIX}/${sysroot_arch}-conda-linux-gnu/sysroot" \
#     "${SRC_DIR}/_conda-build-${qemu_arch}" \
#     "${SRC_DIR}/_conda-install-${qemu_arch}"
# fi
