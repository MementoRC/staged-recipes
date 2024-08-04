# --- Function definitions ---

# Set environment variables
$env:npm_config_build_from_source = $true
$env:npm_config_legacy_peer_deps = $true
$env:NPM_CONFIG_USERCONFIG = "/tmp/nonexistentrc"

# Define conda packages
$main_package="@dydxprotocol/v4-client-js"

New-Item -ItemType Directory -Path "$env:SRC_DIR/$main_package" -Force
Push-Location "$env:SRC_DIR/js_module_source/v4-client-js"
    $tempTarFile = [System.IO.Path]::GetTempFileName()
    tar -cf $tempTarFile .
    tar -xf $tempTarFile -C "$env:SRC_DIR/$main_package"
    Remove-Item $tempTarFile
Pop-Location

# Navigate to directory and run commands
Push-Location $env:SRC_DIR/$main_package
    Get-ChildItem -Path . -Recurse
    # Build
    pnpm install
    pnpm run compile

    # Install
    pnpm install

    # Generate licenses
    . "${env:RECIPE_DIR}/helpers/js_build.ps1"
    Third-Party-Licenses "$env:SRC_DIR/$main_package"
    Copy-Item -Path "LICENSE" "$env:SRC_DIR/LICENSE"

    # Pack and install
    pnpm pack
Pop-Location
