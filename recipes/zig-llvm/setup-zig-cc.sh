# === setup_zig_cc: Configure zig as C/C++ compiler for CMake ===
# Exports ZIG_CC, ZIG_CXX, ZIG_AR, etc. for use with CMake
#
# On Windows: Uses CMake semicolon-separated syntax (no wrapper scripts needed)
# On Unix: Creates wrapper scripts to filter out GCC-specific flags from conda

setup_zig_cc() {
    local zig="$1"
    local target="${2:-native}"
    local mcpu="${3:-baseline}"
    local wrapper_dir="${SRC_DIR}/zig-cc-wrappers"

    if [[ -z "${zig}" ]]; then
        echo "ERROR: setup_zig_cc requires zig binary path" >&2
        return 1
    fi

    mkdir -p "${wrapper_dir}"

    # Detect Windows (use :- to avoid unbound variable error with set -u)
    if [[ "${OSTYPE:-}" == "msys" ]] || [[ "${OSTYPE:-}" == "cygwin" ]] || [[ -n "${MSYSTEM:-}" ]] || [[ "${zig}" == *.exe ]]; then
        _setup_zig_cc_windows "${zig}" "${target}" "${mcpu}" "${wrapper_dir}"
    else
        # On Linux/macOS, find the conda sysroot so the wrapper passes -isysroot.
        # This ensures CMake's check_symbol_exists() probes see the sysroot headers
        # (glibc 2.17) rather than the host system headers (glibc 2.36+), which
        # would otherwise cause LLVM to compile in calls to symbols that don't
        # exist in the target glibc.
        local sysroot=""
        # conda-forge sysroot_linux-* packages install here:
        local arch="${target%%-*}"  # e.g. x86_64 from x86_64-linux-gnu.2.17
        local conda_sysroot="${BUILD_PREFIX}/${arch}-conda-linux-gnu/sysroot"
        if [[ -d "${conda_sysroot}" ]]; then
            sysroot="${conda_sysroot}"
        elif [[ -n "${CONDA_BUILD_SYSROOT:-}" ]] && [[ -d "${CONDA_BUILD_SYSROOT}" ]]; then
            sysroot="${CONDA_BUILD_SYSROOT}"
        fi

        if [[ -n "${sysroot}" ]]; then
            echo "  Sysroot:    ${sysroot}"
        else
            echo "  WARNING: No conda sysroot found; CMake probes will use host headers"
        fi

        _setup_zig_cc_unix "${zig}" "${target}" "${mcpu}" "${wrapper_dir}" "${sysroot}"
    fi

    # Clear conda's compiler flags - zig handles optimization internally
    unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
    export CFLAGS="" CXXFLAGS="" LDFLAGS="" CPPFLAGS=""

    echo "=== setup_zig_cc: Configured zig compiler ==="
    echo "  ZIG_CC:     ${ZIG_CC}"
    echo "  ZIG_CXX:    ${ZIG_CXX}"
    echo "  ZIG_AR:     ${ZIG_AR}"
    echo "  Target:     ${target}"
    echo "  MCPU:       ${mcpu}"
}

# Windows: Use CMake semicolon-separated compiler syntax (like zig upstream)
_setup_zig_cc_windows() {
    local zig="$1"
    local target="$2"
    local mcpu="$3"
    local wrapper_dir="$4"

    # Ensure .exe extension on Windows (CMake requires full path with extension)
    if [[ "${zig}" != *.exe ]]; then
        if [[ -x "${zig}.exe" ]]; then
            zig="${zig}.exe"
        fi
    fi

    # CMake accepts semicolon-separated "compiler;arg1;arg2" format
    # This avoids needing wrapper scripts on Windows
    export ZIG_CC="${zig};cc;-target;${target};-mcpu=${mcpu}"
    export ZIG_CXX="${zig};c++;-target;${target};-mcpu=${mcpu}"
    export ZIG_ASM="${zig};cc;-target;${target};-mcpu=${mcpu}"
    export ZIG_AR="${zig};ar"
    export ZIG_RANLIB="${zig};ranlib"
    # RC compiler: try llvm-rc from build prefix, or leave unset (LLVM can build without it)
    local llvm_rc="${BUILD_PREFIX}/Library/bin/llvm-rc.exe"
    if [[ -x "${llvm_rc}" ]]; then
        export ZIG_RC="${llvm_rc}"
    else
        export ZIG_RC=""
    fi
}

# Unix (Linux/macOS): Create wrapper scripts with flag filtering
_setup_zig_cc_unix() {
    local zig="$1"
    local target="$2"
    local mcpu="$3"
    local wrapper_dir="$4"
    local sysroot="${5:-}"

    # Build the fixed flags baked into every zig cc/c++ invocation.
    # -isysroot makes zig cc use the conda sysroot headers instead of the host's,
    # which is critical so that CMake's check_symbol_exists() probes see the
    # correct glibc 2.17 API rather than the host glibc (2.36+).
    local sysroot_flag=""
    if [[ -n "${sysroot}" ]]; then
        sysroot_flag="-isysroot ${sysroot}"
    fi

    # Sysroot lib flags: prepend sysroot lib dirs so the linker finds the
    # glibc 2.17 libm/libpthread/libdl from the sysroot BEFORE the conda
    # host env libs (which may be glibc 2.29+/2.34+).
    local sysroot_lib_flags=""
    if [[ -n "${sysroot}" ]]; then
        sysroot_lib_flags="-L${sysroot}/usr/lib64 -L${sysroot}/usr/lib -L${sysroot}/lib64 -L${sysroot}/lib"
    fi

    # libc_nonshared.a: provides atexit, stat64, fstat64, lstat64, __stat, __fstat,
    # __lstat, __mknod, etc. that are NOT exported as dynamic symbols from libc.so.6.
    # Needed by LLVM shared libs when linked with ld.lld directly (bypassing zig cc).
    local sysroot_libc_nonshared=""
    if [[ -n "${sysroot}" ]] && [[ -e "${sysroot}/usr/lib64/libc_nonshared.a" ]]; then
        sysroot_libc_nonshared="${sysroot}/usr/lib64/libc_nonshared.a"
    elif [[ -n "${sysroot}" ]] && [[ -e "${sysroot}/usr/lib/libc_nonshared.a" ]]; then
        sysroot_libc_nonshared="${sysroot}/usr/lib/libc_nonshared.a"
    fi


    # _make_filter_wrapper <output_file> <zig_subcommand>
    # Writes a wrapper that strips GCC/GNU ld flags zig's lld doesn't accept,
    # then execs zig <subcommand> with the fixed flags prepended.
    _make_filter_wrapper() {
        local out="$1"
        local subcmd="$2"
        cat > "${out}" << EOF
#!/usr/bin/env bash
# Wrapper: zig ${subcmd} -target ${target} -mcpu=${mcpu} ${sysroot_flag}
# Strips GCC/GNU ld flags unsupported by zig's lld.
# Prepends sysroot lib dirs so -lm/-lpthread/-ldl resolve against glibc 2.17
# rather than the conda host env libs.
args=()
i=0
argv=("\$@")
argc=\${#argv[@]}

while [[ \$i -lt \$argc ]]; do
    arg="\${argv[\$i]}"
    case "\$arg" in
        -Xlinker)
            next_i=\$((i + 1))
            if [[ \$next_i -lt \$argc ]]; then
                next_arg="\${argv[\$next_i]}"
                case "\$next_arg" in
                    -Bsymbolic-functions|-Bsymbolic|--color-diagnostics|--dependency-file=*)
                        i=\$next_i ;;
                    *)
                        args+=("\$arg" "\$next_arg")
                        i=\$next_i ;;
                esac
            fi
            ;;
        -Wl,-rpath-link|-Wl,-rpath-link,*|-Wl,--disable-new-dtags) ;;
        -Wl,--allow-shlib-undefined|-Wl,--no-allow-shlib-undefined) ;;
        -Wl,-Bsymbolic-functions|-Wl,-Bsymbolic) ;;
        -Wl,--color-diagnostics) ;;
        -Wl,--version-script|-Wl,--version-script,*) ;;
        -Wl,-z,defs|-Wl,-z,nodelete|-Wl,-z,*) ;;
        -Wl,-O*) ;;
        -Wl,--gc-sections|-Wl,--no-gc-sections) ;;
        -Wl,--build-id|-Wl,--build-id=*) ;;
        -Wl,-all_load|-Wl,-force_load,*) ;;
        -all_load|-force_load) ;;
        -Bsymbolic-functions|-Bsymbolic) ;;
        -march=*|-mtune=*|-ftree-vectorize) ;;
        -fstack-protector-strong|-fstack-protector|-fno-plt) ;;
        -fdebug-prefix-map=*) ;;
        -stdlib=*) ;;
        *) args+=("\$arg") ;;
    esac
    ((i++))
done
# Strip -nostdlib++ (zig doesn't recognize it).  Shared library links use
# the zig-cxx-shared wrapper via CMAKE_CXX_CREATE_SHARED_LIBRARY, so this
# wrapper is only invoked for compilation and executable linking.
_final_args=()
_saw_nostdlibxx=0
for _a in "\${args[@]}"; do
    if [[ "\$_a" == "-nostdlib++" ]]; then
        _saw_nostdlibxx=1
    else
        _final_args+=("\$_a")
    fi
done

if [[ \${_saw_nostdlibxx} -eq 1 ]]; then
    _use_subcmd="cc"
else
    _use_subcmd="${subcmd}"
fi
exec "${zig}" \${_use_subcmd} -target ${target} -mcpu=${mcpu} ${sysroot_flag} ${sysroot_lib_flags} "\${_final_args[@]}"
EOF
        chmod +x "${out}"
    }

    _make_filter_wrapper "${wrapper_dir}/zig-cc"  "cc"
    _make_filter_wrapper "${wrapper_dir}/zig-cxx" "c++"

    # Simple wrappers for ar, ranlib, asm, rc
    cat > "${wrapper_dir}/zig-ar" << EOF
#!/usr/bin/env bash
exec "${zig}" ar "\$@"
EOF
    chmod +x "${wrapper_dir}/zig-ar"

    cat > "${wrapper_dir}/zig-ranlib" << EOF
#!/usr/bin/env bash
exec "${zig}" ranlib "\$@"
EOF
    chmod +x "${wrapper_dir}/zig-ranlib"

    cat > "${wrapper_dir}/zig-asm" << EOF
#!/usr/bin/env bash
exec "${zig}" cc -target ${target} -mcpu=${mcpu} ${sysroot_flag} "\$@"
EOF
    chmod +x "${wrapper_dir}/zig-asm"

    cat > "${wrapper_dir}/zig-rc" << EOF
#!/usr/bin/env bash
exec "${zig}" rc "\$@"
EOF
    chmod +x "${wrapper_dir}/zig-rc"

    # zig-cxx-shared: wrapper for creating shared libraries.
    # zig cc/c++ ALWAYS auto-merges its bundled static hidden-visibility libc++
    # into every .so at link time.  The only solution is to bypass zig entirely
    # and invoke ld.lld (or ld) directly for the shared library link step.
    #
    # The .o files compiled by zig c++ are standard ELF — any linker handles them.
    # We link with -lc++ -lc++abi (from CMAKE_SHARED_LINKER_FLAGS) and nothing else.
    # No gcc, no libstdc++, no sysroot — just zig's .o files + our shared libc++.
    #
    # We use ld.lld from the build prefix (provided by llvmdev or lld package),
    # falling back to ld from PATH.
    local build_ld=""
    for _cand in \
        "${BUILD_PREFIX}/bin/ld.lld" \
        "${BUILD_PREFIX}/bin/lld" \
        "$(command -v ld.lld 2>/dev/null || true)" \
        "$(command -v ld 2>/dev/null || true)"; do
        if [[ -n "${_cand}" ]] && [[ -x "${_cand}" ]]; then
            build_ld="${_cand}"
            break
        fi
    done
    if [[ -z "${build_ld}" ]]; then
        echo "ERROR: No linker (ld.lld or ld) found for zig-cxx-shared wrapper" >&2
        return 1
    fi
    echo "  zig-cxx-shared linker: ${build_ld}"
    if [[ -n "${sysroot_libc_nonshared}" ]]; then
        echo "  zig-cxx-shared libc_nonshared: ${sysroot_libc_nonshared}"
    fi

    cat > "${wrapper_dir}/zig-cxx-shared" << EOF
#!/usr/bin/env bash
# Shared-library link wrapper: invokes ld.lld directly (not zig, not gcc).
# Translates compiler-driver flags (-Wl,X → X, -Xlinker X → X, strips
# -fFOO/-OFOO etc.) into raw linker flags.
# Prepends sysroot lib dirs so -lrt/-ldl/-lm resolve from conda glibc 2.17.
args=()
_skip_next=0
_grab_next=0
for arg in "\$@"; do
    if [[ \${_skip_next} -eq 1 ]]; then
        _skip_next=0
        continue
    fi
    # -Xlinker <arg>: grab the next arg as a raw linker flag
    if [[ \${_grab_next} -eq 1 ]]; then
        _grab_next=0
        case "\$arg" in
            # Filter flags that lld doesn't accept or we don't want
            -Bsymbolic-functions|-Bsymbolic|--color-diagnostics|--dependency-file=*) ;;
            *) args+=("\$arg") ;;
        esac
        continue
    fi
    case "\$arg" in
        # Compiler-driver flags that the raw linker doesn't understand
        -target) _skip_next=1 ;;
        -mcpu=*|-nostdlib++|-stdlib=*) ;;
        -f*|-O*|-g|-g[0-9]*|-W[^l]*|-D*|-I*|-std=*) ;;
        # -Xlinker: next arg is a raw linker flag
        -Xlinker) _grab_next=1 ;;
        # Strip -z defs: requires all symbols resolved at link time.
        # Shared libs by default allow undefined symbols (resolved at dlopen time),
        # but -z defs overrides this.  libc_nonshared.a defines atexit (not in libc.so.6);
        # lld will pull in atexit.oS from the archive since -z defs is not active.
        -Wl,-z,defs) ;;
        # Unwrap -Wl, prefixed args into raw linker args
        -Wl,*)
            IFS=',' read -ra _wl_parts <<< "\${arg#-Wl,}"
            for _p in "\${_wl_parts[@]}"; do
                [[ -n "\${_p}" ]] && args+=("\${_p}")
            done
            ;;
        *) args+=("\$arg") ;;
    esac
done
# lld shared library mode: undefined symbols from .o files are allowed by default.
# -z defs is filtered above, which is the flag that would require all symbols resolved.
# libc_nonshared.a: provides atexit, stat64, fstat64, __stat, __fstat, __mknod etc.
# that libc.so.6 does NOT export as dynamic symbols. With this archive present, lld
# pulls in the atexit.oS wrapper that calls __cxa_atexit (which IS in libc.so.6).
exec "${build_ld}" "\${args[@]}" ${sysroot_lib_flags} ${sysroot_libc_nonshared}
EOF
    chmod +x "${wrapper_dir}/zig-cxx-shared"

    export ZIG_AR="${wrapper_dir}/zig-ar"
    export ZIG_ASM="${wrapper_dir}/zig-asm"
    export ZIG_CC="${wrapper_dir}/zig-cc"
    export ZIG_CXX="${wrapper_dir}/zig-cxx"
    export ZIG_CXX_SHARED="${wrapper_dir}/zig-cxx-shared"
    export ZIG_RANLIB="${wrapper_dir}/zig-ranlib"
    export ZIG_RC="${wrapper_dir}/zig-rc"
}
