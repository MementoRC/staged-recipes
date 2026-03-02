#!/usr/bin/env bash
# Build LLVM with zig cc for zig-llvmdev package
# This produces LLVM/Clang/LLD shared libraries with libc++ ABI
# compatible with zig-cc-built zigcpp

set -euxo pipefail
IFS=$'\n\t'

if [[ ${BASH_VERSINFO[0]} -lt 5 || (${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -lt 2) ]]; then
  echo "ERROR: This script requires bash 5.2 or later (found ${BASH_VERSION})"
  echo "Attempting to re-exec with conda bash..."
  if [[ -x "${BUILD_PREFIX}/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/bin/bash" "$0" "$@"
  elif [[ -x "${BUILD_PREFIX}/Library/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/Library/bin/bash" "$0" "$@"
  else
    echo "ERROR: Could not find conda bash at ${BUILD_PREFIX}/bin/bash"
    exit 1
  fi
fi

source ${RECIPE_DIR}/post-install.sh
source ${RECIPE_DIR}/remove-unneeded.sh
source ${RECIPE_DIR}/setup-zig-cc.sh

echo "=== Building zig-llvmdev with zig cc ==="
echo "  LLVM source: ${SRC_DIR}/llvm-source"
echo "  Target: ${target_platform}"

# Get bootstrap zig - install via mamba to break cycle
# zig-llvmdev needs zig cc, but we're building zig, so use previous version
# Check multiple locations for Windows/Unix compatibility
BOOTSTRAP_ZIG=""
for candidate in \
  "${BUILD_PREFIX}/bin/zig" \
  "${BUILD_PREFIX}/bin/zig.exe" \
  "${BUILD_PREFIX}/Library/bin/zig.exe"; do
  if [[ -x "${candidate}" ]]; then
      BOOTSTRAP_ZIG="${candidate}"
      break
  fi
done
if [[ -z "${BOOTSTRAP_ZIG}" ]]; then
  echo "ERROR: Bootstrap zig not found in BUILD_PREFIX"
  exit 1
fi
echo "  Bootstrap zig: ${BOOTSTRAP_ZIG} ($(${BOOTSTRAP_ZIG} version))"

# Build directories (set before setup_zig_cc so LLVM_INSTALL is available in wrapper)
# Install to lib/zig-llvm to avoid conflicts with conda-forge llvmdev
LLVM_SRC="${SRC_DIR}/llvm"
LLVM_BUILD="${SRC_DIR}/conda-llvm-build"
LLVM_INSTALL="${PREFIX}/lib/zig-llvm"

# Cross-compilation detection and setup
# CONDA_BUILD_CROSS_COMPILATION is set by conda-build when build_platform != target_platform
CMAKE_CROSS_FLAGS=()
if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
  echo "=== Cross-compilation detected ==="
  echo "  Build platform: ${build_platform}"
  echo "  Target platform: ${target_platform}"

  # Determine target system name for cmake
  case "${target_platform}" in
    linux-*)
      CMAKE_SYSTEM_NAME="Linux" ;;
    osx-*)
      CMAKE_SYSTEM_NAME="Darwin" ;;
    win-*)
      CMAKE_SYSTEM_NAME="Windows" ;;
    *)
      echo "ERROR: Unknown target platform family: ${target_platform}"
      exit 1 ;;
  esac

  # Tablegen tools run on the BUILD host, not target.
  # Provided by zig-llvm itself (build dep for cross-compilation).
  LLVM_TBLGEN=""
  CLANG_TBLGEN=""
  for _prefix in "${BUILD_PREFIX}/lib/zig-llvm" "${BUILD_PREFIX}"; do
    if [[ -x "${_prefix}/bin/llvm-tblgen" ]] && [[ -x "${_prefix}/bin/clang-tblgen" ]]; then
      LLVM_TBLGEN="${_prefix}/bin/llvm-tblgen"
      CLANG_TBLGEN="${_prefix}/bin/clang-tblgen"
      break
    fi
  done

  if [[ -z "${LLVM_TBLGEN}" ]]; then
    echo "ERROR: llvm-tblgen/clang-tblgen not found"
    echo "  Cross-compilation requires zig-llvm as a build dependency"
    exit 1
  fi

  CMAKE_CROSS_FLAGS=(
    -DCMAKE_CROSSCOMPILING=True
    -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}"
    -DCMAKE_INSTALL_INCLUDEDIR=include
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_INSTALL_BINDIR=bin
    -DCMAKE_SYSTEM_NAME="${CMAKE_SYSTEM_NAME}"
    -DLLVM_TABLEGEN="${LLVM_TBLGEN}"
    -DCLANG_TABLEGEN="${CLANG_TBLGEN}"
    -DLLVM_DEFAULT_TARGET_TRIPLE="${LLVM_TRIPLET}"
    -DLLVM_HOST_TRIPLE="${LLVM_TRIPLET}"
  )

  echo "  CMAKE_SYSTEM_NAME: ${CMAKE_SYSTEM_NAME}"
  echo "  LLVM_TABLEGEN: ${LLVM_TBLGEN}"
  echo "  CLANG_TABLEGEN: ${CLANG_TBLGEN}"
fi

# Setup zig as C/C++ compiler (works for both native and cross-compilation)
echo "  ZIG_TRIPLET: ${ZIG_TRIPLET}"
setup_zig_cc "${BOOTSTRAP_ZIG}" "${ZIG_TRIPLET}" "baseline"

# LLVM_TRIPLET is set by recipe.yaml env (standard LLVM triple, no glibc version suffix)
echo "  LLVM_TRIPLET: ${LLVM_TRIPLET}"

# Platform-specific CMake flags
CMAKE_PLATFORM_FLAGS=()
case "${target_platform}" in
  linux-*)
    CMAKE_PLATFORM_FLAGS=(
      -DHAVE_DECL_ARC4RANDOM=0
      -DHAVE_MALLINFO2=0
      -DHAVE_PTHREAD_GETNAME_NP=0
      -DHAVE_PTHREAD_SETNAME_NP=0
    )
    ;;
  osx-*)
    CMAKE_PLATFORM_FLAGS=(
    )
    ;;
  win-*)
    # Windows: Use static MSVC runtime, explicit zstd shared lib paths
    CMAKE_PLATFORM_FLAGS=(
      -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
      -DLLVM_USE_INTEL_JITEVENTS=ON
      -DLLVM_ENABLE_DUMP=ON
      -Dzstd_INCLUDE_DIR="${PREFIX}/Library/include"
      -Dzstd_LIBRARY="${PREFIX}/Library/lib/zstd.lib"
    )
    ;;
esac

# === BUILD CACHE ===
# For faster iteration on packaging/tests, cache built artifacts in recipe folder
# Cache location: ${RECIPE_DIR}/cache/zig-llvm/
#
# To populate cache from a successful build:
#   cp -r output/bld/rattler-build_zig-llvm_*/host_env_*/lib/zig-llvm recipes/zig-llvm/cache/
#   cp output/bld/rattler-build_zig-llvm_*/host_env_*/lib/zig-llvm-path.txt recipes/zig-llvm/cache/
#
# Set ZIG_LLVM_FORCE_BUILD=1 to ignore cache and rebuild

CACHE_DIR="${RECIPE_DIR}/cache"

if [[ "${ZIG_LLVM_SKIP_BUILD:-0}" == "1" ]] && [[ -d "${CACHE_DIR}" ]] && \
   [[ -x "${CACHE_DIR}/bin/llvm-config" ]] && \
   [[ -n "$(ls "${CACHE_DIR}/lib/"libLLVM*.{dll,dylib,so}* 2>/dev/null | head -1)" ]]; then
  echo "=== USING CACHED LLVM BUILD ==="
  echo "  Cache found at: ${CACHE_DIR}"
  echo "  llvm-config version: $("${CACHE_DIR}/bin/llvm-config" --version)"
  echo ""
  echo "  Copying cache to: ${LLVM_INSTALL}"

  mkdir -p "${PREFIX}/lib"
  cp -a "${CACHE_DIR}" "${LLVM_INSTALL}"
  post_install
  remove_unneeded

  # Create marker file
  echo "${LLVM_INSTALL}" > "${PREFIX}/lib/zig-llvm-path.txt"

  echo "  Cache installed successfully!"
  echo "  Set ZIG_LLVM_FORCE_BUILD=1 to rebuild from source"
  ls -la "${LLVM_INSTALL}/lib/"*.so* | head -10
  exit 0
fi

if [[ "${ZIG_LLVM_SKIP_BUILD:-0}" != "1" ]]; then
  echo "=== LLVM Full BUILD (ZIG_LLVM_SKIP_BUILD=0) ==="
elif [[ -d "${CACHE_DIR}" ]]; then
  echo "=== Cache found but incomplete, rebuilding ==="
else
  echo "=== No cache found, building from source ==="
  echo "  To speed up future builds, populate cache after successful build:"
  echo "    mkdir -p ${RECIPE_DIR}/cache"
  echo "    cp -r \${PREFIX}/lib/zig-llvm ${RECIPE_DIR}/cache/"
fi

mkdir -p "${LLVM_BUILD}"

if [[ "${target_platform}" == linux-* ]] || [[ "${target_platform}" == osx-* ]]; then
  echo "=== Building libc++/libc++abi/libunwind with zig cc (-fvisibility=default) ==="
  # Build runtimes BEFORE LLVM so libLLVM.so links against the already-installed
  # libc++.so.1 (NEEDED entry). Built with -fvisibility=default so symbols are
  # genuinely public and shared — not hidden copies merged into each .so.
  # Build order: libunwind → libcxxabi → libcxx.
  LIBCXX_SRC="${SRC_DIR}/runtimes"

  _RUNTIMES_CMAKE=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}"
    -DCMAKE_C_COMPILER="${ZIG_CC}"
    -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
    -DCMAKE_ASM_COMPILER="${ZIG_ASM}"
    -DCMAKE_AR="${ZIG_AR}"
    -DCMAKE_RANLIB="${ZIG_RANLIB}"
    # Override zig cc's default -fvisibility=hidden so libc++ symbols are public
    # and genuinely shared between libLLVM.so and libclang-cpp.so.
    -DCMAKE_C_FLAGS="-fvisibility=default"
    -DCMAKE_CXX_FLAGS="-fvisibility=default"
    -DCMAKE_SKIP_RPATH=ON
    -DLLVM_CONFIG_PATH="${BUILD_PREFIX}/bin/llvm-config"
  )

  # Build all three runtimes in one invocation so inter-dependencies (libcxxabi
  # needing libunwind in LLVM_ENABLE_RUNTIMES) are satisfied automatically.
  echo "  Building libunwind + libcxxabi + libcxx..."
  mkdir -p "${SRC_DIR}/conda-runtimes-build"
  cmake -S "${LIBCXX_SRC}" -B "${SRC_DIR}/conda-runtimes-build" \
    "${_RUNTIMES_CMAKE[@]}" \
    -DLLVM_ENABLE_RUNTIMES="libunwind;libcxxabi;libcxx" \
    -DLIBUNWIND_ENABLE_SHARED=ON \
    -DLIBUNWIND_ENABLE_STATIC=OFF \
    -DLIBUNWIND_USE_COMPILER_RT=ON \
    -DLIBCXXABI_ENABLE_SHARED=ON \
    -DLIBCXXABI_ENABLE_STATIC=OFF \
    -DLIBCXXABI_USE_COMPILER_RT=ON \
    -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
    -DLIBCXX_ENABLE_SHARED=ON \
    -DLIBCXX_ENABLE_STATIC=OFF \
    -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=OFF \
    -DLIBCXX_USE_COMPILER_RT=ON \
    -DLIBCXX_CXX_ABI=libcxxabi \
    -G Ninja
  cmake --build "${SRC_DIR}/conda-runtimes-build" -j"${CPU_COUNT}"
  cmake --install "${SRC_DIR}/conda-runtimes-build"

  echo "  libc++ runtimes installed to ${LLVM_INSTALL}/lib"

  # === Verify libc++ runtimes and symlinks ===
  echo "=== Verifying libc++ runtime installation ==="
  ls -la "${LLVM_INSTALL}/lib/"libc++* || true

  # Ensure linker symlinks exist (CMake install may skip them)
  if [[ ! -e "${LLVM_INSTALL}/lib/libc++.so.1" ]]; then
    ln -sf libc++.so.1.0 "${LLVM_INSTALL}/lib/libc++.so.1"
  fi
  if [[ ! -e "${LLVM_INSTALL}/lib/libc++abi.so" ]]; then
    ln -sf libc++abi.so.1.0 "${LLVM_INSTALL}/lib/libc++abi.so"
  fi
  if [[ ! -e "${LLVM_INSTALL}/lib/libc++abi.so.1" ]]; then
    ln -sf libc++abi.so.1.0 "${LLVM_INSTALL}/lib/libc++abi.so.1"
  fi

fi

_CLANG=(
  -DCLANG_ENABLE_OBJC_REWRITER=ON
  -DCLANG_LINK_CLANG_DYLIB=ON

  -DCLANG_BUILD_TOOLS=OFF
  -DCLANG_ENABLE_ARCMT=OFF
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF
  -DCLANG_INCLUDE_DOCS=OFF
  -DCLANG_INCLUDE_TESTS=OFF
  -DCLANG_TOOL_CLANG_IMPORT_TEST_BUILD=OFF
  -DCLANG_TOOL_CLANG_LINKER_WRAPPER_BUILD=OFF
  -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF
  -DCLANG_TOOL_LIBCLANG_BUILD=OFF
)

_LLVM=(
  -DLLVM_BUILD_TOOLS=ON
  -DLLVM_BUILD_LLVM_DYLIB=ON
  -DLLVM_DYLIB_COMPONENTS="all"
  -DLLVM_ENABLE_LIBCXX=ON
  -DLLVM_ENABLE_LIBXML2=ON
  -DLLVM_ENABLE_PROJECTS="clang;lld"
  -DLLVM_ENABLE_RTTI=ON
  -DLLVM_ENABLE_ZLIB=ON
  -DLLVM_ENABLE_ZSTD=ON
  -DLLVM_LINK_LLVM_DYLIB=ON
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64;ARM;PowerPC;RISCV;WebAssembly;SystemZ;AMDGPU;AVR;NVPTX"
  -DLLVM_TOOL_LLVM_CONFIG_BUILD=ON

  -DLLVM_DEFAULT_TARGET_TRIPLE="${LLVM_TRIPLET}"
  -DLLVM_BUILD_UTILS=OFF
  -DLLVM_ENABLE_ASSERTIONS=OFF
  -DLLVM_ENABLE_BACKTRACES=OFF
  -DLLVM_ENABLE_BINDINGS=OFF
  -DLLVM_ENABLE_CRASH_OVERRIDES=OFF
  -DLLVM_ENABLE_LIBEDIT=OFF
  -DLLVM_ENABLE_LIBPFM=OFF
  -DLLVM_ENABLE_OCAMLDOC=OFF
  -DLLVM_ENABLE_PLUGINS=OFF
  -DLLVM_ENABLE_Z3_SOLVER=OFF
  -DLLVM_HAS_LOGF128=OFF
  -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_DOCS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_INCLUDE_TESTS=OFF
  -DLLVM_INCLUDE_UTILS=OFF
  -DLLVM_INSTALL_TOOLCHAIN_ONLY=OFF
  # Disable all tools except llvm-config (saves significant build time)
  -DLLVM_TOOL_BUGPOINT_BUILD=OFF
  -DLLVM_TOOL_DSYMUTIL_BUILD=OFF
  -DLLVM_TOOL_GOLD_BUILD=OFF
  -DLLVM_TOOL_LLC_BUILD=OFF
  -DLLVM_TOOL_LLI_BUILD=OFF
  -DLLVM_TOOL_LLVM_AR_BUILD=OFF
  -DLLVM_TOOL_LLVM_AS_BUILD=OFF
  -DLLVM_TOOL_LLVM_BCANALYZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_CAT_BUILD=OFF
  -DLLVM_TOOL_LLVM_CFI_VERIFY_BUILD=OFF
  -DLLVM_TOOL_LLVM_COV_BUILD=OFF
  -DLLVM_TOOL_LLVM_CVTRES_BUILD=OFF
  -DLLVM_TOOL_LLVM_CXXDUMP_BUILD=OFF
  -DLLVM_TOOL_LLVM_CXXFILT_BUILD=OFF
  -DLLVM_TOOL_LLVM_CXXMAP_BUILD=OFF
  -DLLVM_TOOL_LLVM_DIFF_BUILD=OFF
  -DLLVM_TOOL_LLVM_DIS_BUILD=OFF
  -DLLVM_TOOL_LLVM_DWARFDUMP_BUILD=OFF
  -DLLVM_TOOL_LLVM_DWARFUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_DWP_BUILD=OFF
  -DLLVM_TOOL_LLVM_EXEGESIS_BUILD=OFF
  -DLLVM_TOOL_LLVM_EXTRACT_BUILD=OFF
  -DLLVM_TOOL_LLVM_GSYMUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_IFS_BUILD=OFF
  -DLLVM_TOOL_LLVM_JITLINK_BUILD=OFF
  -DLLVM_TOOL_LLVM_LINK_BUILD=OFF
  -DLLVM_TOOL_LLVM_LIPO_BUILD=OFF
  -DLLVM_TOOL_LLVM_LTO2_BUILD=OFF
  -DLLVM_TOOL_LLVM_LTO_BUILD=OFF
  -DLLVM_TOOL_LLVM_MCA_BUILD=OFF
  -DLLVM_TOOL_LLVM_MC_BUILD=OFF
  -DLLVM_TOOL_LLVM_ML_BUILD=OFF
  -DLLVM_TOOL_LLVM_MODEXTRACT_BUILD=OFF
  -DLLVM_TOOL_LLVM_MT_BUILD=OFF
  -DLLVM_TOOL_LLVM_NM_BUILD=OFF
  -DLLVM_TOOL_LLVM_OBJCOPY_BUILD=OFF
  -DLLVM_TOOL_LLVM_OBJDUMP_BUILD=OFF
  -DLLVM_TOOL_LLVM_OPT_REPORT_BUILD=OFF
  -DLLVM_TOOL_LLVM_PDBUTIL_BUILD=OFF
  -DLLVM_TOOL_LLVM_PROFDATA_BUILD=OFF
  -DLLVM_TOOL_LLVM_PROFGEN_BUILD=OFF
  -DLLVM_TOOL_LLVM_RC_BUILD=OFF
  -DLLVM_TOOL_LLVM_READOBJ_BUILD=OFF
  -DLLVM_TOOL_LLVM_REDUCE_BUILD=OFF
  -DLLVM_TOOL_LLVM_RTDYLD_BUILD=OFF
  -DLLVM_TOOL_LLVM_SIM_BUILD=OFF
  -DLLVM_TOOL_LLVM_SIZE_BUILD=OFF
  -DLLVM_TOOL_LLVM_SPLIT_BUILD=OFF
  -DLLVM_TOOL_LLVM_STRESS_BUILD=OFF
  -DLLVM_TOOL_LLVM_STRINGS_BUILD=OFF
  -DLLVM_TOOL_LLVM_SYMBOLIZER_BUILD=OFF
  -DLLVM_TOOL_LLVM_TLI_CHECKER_BUILD=OFF
  -DLLVM_TOOL_LLVM_UNDNAME_BUILD=OFF
  -DLLVM_TOOL_LLVM_XRAY_BUILD=OFF
  -DLLVM_TOOL_LTO_BUILD=OFF
  -DLLVM_TOOL_OBJ2YAML_BUILD=OFF
  -DLLVM_TOOL_OPT_BUILD=OFF
  -DLLVM_TOOL_REMARKS_SHLIB_BUILD=OFF
  -DLLVM_TOOL_SANCOV_BUILD=OFF
  -DLLVM_TOOL_SANSTATS_BUILD=OFF
  -DLLVM_TOOL_VERIFY_USELISTORDER_BUILD=OFF
  -DLLVM_TOOL_VFABI_DEMANGLE_FUZZER_BUILD=OFF
  -DLLVM_TOOL_XCODE_TOOLCHAIN_BUILD=OFF
  -DLLVM_TOOL_YAML2OBJ_BUILD=OFF
)

echo "=== Configuring LLVM ==="
echo "  Install prefix: ${LLVM_INSTALL} (separate from conda-forge llvmdev)"
_CMAKE=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}"
  -DCMAKE_PREFIX_PATH="${LLVM_INSTALL};${PREFIX};${BUILD_PREFIX}"
  -DCMAKE_LINK_DEPENDS_USE_LINKER=OFF

  -DCMAKE_AR="${ZIG_AR}"
  -DCMAKE_C_COMPILER="${ZIG_CC}"
  -DCMAKE_CXX_COMPILER="${ZIG_CXX}"
  -DCMAKE_ASM_COMPILER="${ZIG_ASM}"
  -DCMAKE_RANLIB="${ZIG_RANLIB}"

  # Rpath settings - build tools (llvm-min-tblgen, etc) need to find conda libs at runtime
  # LLVM_BUILD/lib is where libLLVM.so lives during the build phase - required so
  # libclang-cpp.so links against it by bare soname (not a relative lib/ path).
  -DCMAKE_BUILD_RPATH="${LLVM_INSTALL}/lib;${LLVM_BUILD}/lib;${BUILD_PREFIX}/lib;${PREFIX}/lib"
  -DCMAKE_INSTALL_RPATH="${LLVM_INSTALL}/lib"

  # Shared library link rule override: use zig-cxx-shared wrapper instead of
  # zig c++ for creating .so files.  zig cc/c++ ALWAYS auto-merge zig's
  # bundled static hidden-visibility libc++ into every .so at link time.
  # There is no flag to disable this.  The zig-cxx-shared wrapper bypasses
  # zig entirely and invokes ld.lld directly (no gcc, no libstdc++ dep)
  # for the shared library link step, so libc++.so.1 appears in NEEDED and
  # generic_category resolves from the single shared copy at runtime.
  -DCMAKE_CXX_CREATE_SHARED_LIBRARY="${ZIG_CXX_SHARED} <CMAKE_SHARED_LIBRARY_CXX_FLAGS> <LINK_FLAGS> <CMAKE_SHARED_LIBRARY_CREATE_CXX_FLAGS> <SONAME_FLAG><TARGET_SONAME> -o <TARGET> <OBJECTS> <LINK_LIBRARIES>"
  -DCMAKE_SHARED_LINKER_FLAGS="-L${LLVM_INSTALL}/lib -lc++ -lc++abi"
  -DCMAKE_EXE_LINKER_FLAGS="-L${LLVM_INSTALL}/lib -lc++ -lc++abi"
)

# RC compiler is optional (only needed on Windows, and only if available)
CMAKE_RC_FLAGS=()
if [[ -n "${ZIG_RC:-}" ]]; then
    CMAKE_RC_FLAGS=(-DCMAKE_RC_COMPILER="${ZIG_RC}")
fi

ulimit -n 4096 2>/dev/null || true
cmake -S "${LLVM_SRC}" -B "${LLVM_BUILD}" \
  "${CMAKE_CROSS_FLAGS[@]}" \
  "${CMAKE_PLATFORM_FLAGS[@]}" \
  "${CMAKE_RC_FLAGS[@]}" \
  -DHAS_LOGF128=OFF \
  -DLLD_BUILD_TOOLS=OFF \
  "${_CMAKE[@]}" \
  "${_CLANG[@]}" \
  "${_LLVM[@]}" \
  -G Ninja

# === Fast stub .so test ===
# Before spending hours on the real LLVM build, create a tiny .so that
# references std::generic_category() — exactly what libLLVM.so and
# libclang-cpp.so will do.  Check that the stub .so has:
#   1. No local generic_category (no static libc++ merge)
#   2. UNDEFINED generic_category in dynamic symbols
#   3. libc++.so in NEEDED entries
# This takes seconds, not 40 minutes.
if [[ "${target_platform}" == linux-* ]]; then
  echo "=== Fast stub .so test (verify shared libc++ linkage) ==="
  _stub_dir="${SRC_DIR}/_stub_test"
  mkdir -p "${_stub_dir}"

  # Compile: zig c++ produces .o with generic_category as U (UNDEFINED)
  cat > "${_stub_dir}/stub.cpp" << 'STUBCPP'
#include <system_error>
// Force a reference to generic_category so it appears in the symbol table.
// This mimics what LLVM/Clang code does internally.
const std::error_category* _stub_ref = &std::generic_category();
STUBCPP

  echo "  Compiling stub.cpp with zig c++..."
  "${ZIG_CXX}" -c -fPIC -o "${_stub_dir}/stub.o" "${_stub_dir}/stub.cpp"

  echo "  stub.o generic_category symbols:"
  nm "${_stub_dir}/stub.o" | grep 'generic_category' || echo "    <none>"

  # Link: use the CMAKE_CXX_CREATE_SHARED_LIBRARY wrapper (zig-cxx-shared)
  echo "  Linking stub.so with zig-cxx-shared wrapper..."
  "${ZIG_CXX_SHARED}" -shared -o "${_stub_dir}/stub.so" \
    -L"${LLVM_INSTALL}/lib" -lc++ -lc++abi \
    "${_stub_dir}/stub.o"

  # Check the stub .so
  echo "  === Checking stub.so ==="
  _fail=0

  echo "  --- Check 1: no local generic_category ---"
  _local_syms=$(nm -a "${_stub_dir}/stub.so" 2>/dev/null | grep 'generic_category' || true)
  echo "  nm -a: ${_local_syms:-<none>}"
  if echo "${_local_syms}" | grep -qP '^[0-9a-f]+ [a-z] '; then
    echo "  FAIL: local generic_category — libc++ baked in"
    _fail=1
  else
    echo "  OK"
  fi

  echo "  --- Check 2: UNDEFINED in dynamic symbols ---"
  _dynsym=$(readelf --dyn-syms --wide "${_stub_dir}/stub.so" 2>/dev/null | grep 'generic_category' || true)
  echo "  readelf --dyn-syms: ${_dynsym:-<none>}"
  if [[ -z "${_dynsym}" ]]; then
    echo "  FAIL: not in dynamic symbol table"
    _fail=1
  elif echo "${_dynsym}" | grep -q 'UND'; then
    echo "  OK: UNDEFINED"
  else
    echo "  FAIL: not UNDEFINED"
    _fail=1
  fi

  echo "  --- Check 3: libc++.so in NEEDED ---"
  _needed=$(readelf -d "${_stub_dir}/stub.so" 2>/dev/null | grep NEEDED || true)
  echo "${_needed}" | sed 's/^/    /'
  if echo "${_needed}" | grep -qE 'libc\+\+\.so'; then
    echo "  OK: libc++.so in NEEDED"
  else
    echo "  FAIL: libc++.so NOT in NEEDED"
    _fail=1
  fi

  if [[ ${_fail} -ne 0 ]]; then
    echo ""
    echo "  ============================================================"
    echo "  EARLY ABORT: stub .so test failed."
    echo "  The shared library link setup does not produce a .so that"
    echo "  uses external shared libc++.  The real LLVM build would fail"
    echo "  zig's ZigClangIsLLVMUsingSeparateLibcxx check."
    echo "  ============================================================"
    echo "  Wrapper used: ${ZIG_CXX_SHARED}"
    cat "${ZIG_CXX_SHARED}"
    exit 1
  fi
  echo "  === Stub .so test PASSED ==="
  rm -rf "${_stub_dir}"
fi

echo "=== Building LLVM ==="
cmake --build "${LLVM_BUILD}" -j"${CPU_COUNT}"

echo "=== Installing LLVM ==="
cmake --install "${LLVM_BUILD}"

# Install tablegen tools (not installed by cmake --install, but needed for cross-compilation)
# These are host-arch binaries that run on the build machine to generate .inc files.
echo "=== Installing tablegen tools ==="
for _tbl in llvm-tblgen clang-tblgen llvm-min-tblgen; do
  if [[ -x "${LLVM_BUILD}/bin/${_tbl}" ]]; then
    cp -v "${LLVM_BUILD}/bin/${_tbl}" "${LLVM_INSTALL}/bin/"
  fi
done

if [[ "${ZIG_LLVM_SKIP_BUILD:-}" == "0" ]]; then
  echo "=== Populating the cache ==="
  mkdir -p ${RECIPE_DIR}/cache && rm -rf ${RECIPE_DIR}/cache/*
  cp -r ${PREFIX}/lib/zig-llvm/* ${RECIPE_DIR}/cache/
fi

remove_unneeded
post_install

echo "=== zig-llvm build complete ==="

# Create a marker file for zig build to find this LLVM
echo "${LLVM_INSTALL}" > "${PREFIX}/lib/zig-llvm-path.txt"

