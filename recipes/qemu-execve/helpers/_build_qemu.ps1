function Invoke-CommandWithLogging {
    param([string]$Command)
    Write-Host "Executing: $Command"
    Invoke-Expression $Command *>&1 | Tee-Object -Append -FilePath "$env:SRC_DIR\build_qemu_detailed.log"
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE"
    }
}

function _Build-Qemu {
    param (
        [string]$build_dir,
        [string]$install_dir,
        [string[]]$qemu_args
    )

    Write-Host "Building QEMU in $build_dir"
    New-Item -ItemType Directory -Force -Path $build_dir
    Push-Location $build_dir

    $env:PKG_CONFIG = "$env:BUILD_PREFIX/bin/pkg-config"
    $env:PKG_CONFIG_PATH = "$env:BUILD_PREFIX/lib/pkgconfig"
    $env:PKG_CONFIG_LIBDIR = "$env:BUILD_PREFIX/lib/pkgconfig"

    Invoke-CommandWithLogging "../qemu-source/configure --help"

    $configureArgs = @(
        "--prefix=$install_dir",
        $qemu_args,
        "--disable-bsd-user", "--disable-guest-agent", "--disable-strip", "--disable-werror", "--disable-gcrypt", "--disable-pie",
        "--disable-debug-info", "--disable-debug-tcg", "--enable-docs", "--disable-tcg-interpreter", "--enable-attr",
        "--disable-brlapi", "--disable-linux-aio", "--disable-bzip2", "--disable-cap-ng", "--disable-curl", "--disable-fdt",
        "--disable-glusterfs", "--disable-gnutls", "--disable-nettle", "--disable-gtk", "--disable-rdma", "--disable-libiscsi",
        "--disable-vnc-jpeg", "--disable-kvm", "--disable-lzo", "--disable-curses", "--disable-libnfs", "--disable-numa",
        "--disable-opengl", "--disable-rbd", "--disable-vnc-sasl", "--disable-sdl", "--disable-seccomp",
        "--disable-smartcard", "--disable-snappy", "--disable-spice", "--disable-libusb", "--disable-usb-redir", "--disable-vde",
        "--disable-vhost-net", "--disable-virglrenderer", "--disable-virtfs", "--disable-vnc", "--disable-vte", "--disable-xen",
        "--disable-xen-pci-passthrough", "--disable-system", "--disable-tools"
    )

    Invoke-CommandWithLogging "../qemu-source/configure $($configureArgs -join ' ')"

    & make -j$env:CPU_COUNT > "$env:SRC_DIR/_make-$qemu_arch.log" 2>&1
    & make check > "$env:SRC_DIR/_check-$qemu_arch.log" 2>&1
    & make install > "$env:SRC_DIR/_install-$qemu_arch.log" 2>&1

    Pop-Location
}

# --- Main ---

$qemu_args = @("--target-list=aarch64-softmmu")
Build-Qemu -build_dir $env:SRC_DIR/_conda-build-win-64 -install_dir $env:SRC_DIR/_conda-install-win-64 $qemu_args
