#!/usr/bin/env bash

set -euxo pipefail

# Prepare jimtcl (conda feedstock does not provide header/library)
pushd "${SRC_DIR}"/jimtcl || exit 1
  ./configure \
    --prefix="${SRC_DIR}"/jimtcl-install \
    --disable-docs \
    > "${SRC_DIR}"/_jimtcl_configure.log 2>&1
  make -j"${CPU_COUNT}" > "${SRC_DIR}"/_jimtcl_make.log 2>&1
  make install

  export PATH="${SRC_DIR}"/jimtcl-install/bin:"${PATH}"
  export CFLAGS="-I${SRC_DIR}/jimtcl-install/include ${CFLAGS}"
  export LDFLAGS="-L${SRC_DIR}/jimtcl-install/lib ${LDFLAGS}"
  export PKG_CONFIG_PATH="${SRC_DIR}/jimtcl-install/lib/pkgconfig:${PREFIX}/lib64/pkgconfig:${PKG_CONFIG_PATH}"
popd || exit 1

"${SRC_DIR}"/bootstrap > "${SRC_DIR}"/_bootstrap_openocd.log 2>&1

mkdir -p "${SRC_DIR}/_conda-build"
pushd "${SRC_DIR}/_conda-build" || exit 1
  "${SRC_DIR}"/configure \
    --prefix="${PREFIX}" \
    --enable-shared \
    --disable-static \
    --disable-internal-jimtcl \
    --disable-internal-libjaylink > "${SRC_DIR}"/_configure_openocd.log 2>&1
  make -j"${CPU_COUNT}" > "${SRC_DIR}"/_make_openocd.log 2>&1
  make install
popd || exit 1