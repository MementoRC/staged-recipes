#!/usr/bin/env bash
#
# Conda-forge recommended build recipe
set -euxo pipefail

pushd "${SRC_DIR}"/@dydxprotocol/v4-client-js
  npm install --omit=dev --global "${PKG_NAME}-${PKG_VERSION}.tgz"
popd
