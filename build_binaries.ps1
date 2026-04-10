<#
.SYNOPSIS
    Build Salvium GUI wallet on Windows (standard or no-miner variant).

.DESCRIPTION
    This script drives the MSYS2/MinGW64 build from PowerShell.
    It installs dependencies (if missing), clones the repo (if missing),
    and compiles either the standard or no-miner variant.

.NOTES
    Prerequisites:
      - MSYS2 installed (default: C:\msys64)
      - Internet connection for first-time dependency install and git clone

.EXAMPLE
    .\build-salvium-gui.ps1                          # standard build
    .\build-salvium-gui.ps1 -Variant nominer         # no-miner build
    .\build-salvium-gui.ps1 -SkipDeps                # skip pacman install
    .\build-salvium-gui.ps1 -Clean                   # wipe build dir first
    .\build-salvium-gui.ps1 -RepoPath D:\salvium-gui # use existing checkout
#>

param(
    # "standard" or "nominer"
    [ValidateSet("standard", "nominer")]
    [string]$Variant = "nominer",

    # Path to existing salvium-gui repo. If not set, clones into current dir.
    [string]$RepoPath = "",

    # MSYS2 install location
    [string]$Msys2Root = "C:\msys64",

    # Number of parallel jobs
    [int]$Jobs = [Environment]::ProcessorCount,

    # Skip dependency installation
    [switch]$SkipDeps,

    # Clean build directory before building
    [switch]$Clean,

    # Build static binary
    [switch]$Static
)

$ErrorActionPreference = "Stop"

# ── Validate MSYS2 ──────────────────────────────────────────────────────────
$msys2Bash = Join-Path $Msys2Root "usr\bin\bash.exe"
$mingw64Env = Join-Path $Msys2Root "mingw64.exe"

if (-not (Test-Path $msys2Bash)) {
    Write-Error @"
MSYS2 not found at $Msys2Root.
Install it from https://www.msys2.org/ or pass -Msys2Root <path>.
"@
    exit 1
}

Write-Host "Using MSYS2 at: $Msys2Root" -ForegroundColor Cyan
Write-Host "Variant:        $Variant" -ForegroundColor Cyan
Write-Host "Jobs:           $Jobs" -ForegroundColor Cyan

# ── Helper: run a command in MSYS2 MinGW64 shell ────────────────────────────
function Invoke-Msys2 {
    param([string]$Command, [string]$Description)
    
    Write-Host "`n[$Description]" -ForegroundColor Yellow
    Write-Host "  > $Command" -ForegroundColor DarkGray

    $env:MSYSTEM = "MINGW64"
    $env:CHERE_INVOKING = "1"
    
    & $msys2Bash --login -c $Command
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "$Description failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
}

# ── Step 1: Install dependencies ────────────────────────────────────────────
if (-not $SkipDeps) {
    $packages = @(
        "mingw-w64-x86_64-toolchain",
        "make",
        "mingw-w64-x86_64-cmake",
        "mingw-w64-x86_64-boost",
        "mingw-w64-x86_64-openssl",
        "mingw-w64-x86_64-zeromq",
        "mingw-w64-x86_64-libsodium",
        "mingw-w64-x86_64-hidapi",
        "mingw-w64-x86_64-protobuf-c",
        "mingw-w64-x86_64-libusb",
        "mingw-w64-x86_64-libgcrypt",
        "mingw-w64-x86_64-unbound",
        "mingw-w64-x86_64-pcre",
        "mingw-w64-x86_64-angleproject",
        "mingw-w64-x86_64-qt5",
        "git"
    ) -join " "

    Invoke-Msys2 "pacman -S --noconfirm --needed $packages" "Installing MSYS2 dependencies"
}

# ── Step 2: Clone repo if needed ────────────────────────────────────────────
if ($RepoPath -eq "") {
    $RepoPath = Join-Path (Get-Location) "salvium-gui"
}

if (-not (Test-Path (Join-Path $RepoPath "CMakeLists.txt"))) {
    Write-Host "`nCloning salvium-gui repository..." -ForegroundColor Yellow
    $parentDir = Split-Path $RepoPath -Parent
    if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
    
    Invoke-Msys2 "git clone --recursive https://github.com/salvium/salvium-gui.git '$(($RepoPath -replace '\\', '/'))'""" "Cloning repository"
}

# Convert Windows path to MSYS2 path
$msysRepoPath = $RepoPath -replace '\\', '/'
$msysRepoPath = $msysRepoPath -replace '^([A-Za-z]):', '/$1'
$msysRepoPath = $msysRepoPath.ToLower().Substring(0,2) + $msysRepoPath.Substring(2)

Write-Host "Repo path (MSYS2): $msysRepoPath" -ForegroundColor DarkGray

# ── Step 3: Clean if requested ──────────────────────────────────────────────
if ($Clean) {
    $buildDir = Join-Path $RepoPath "build"
    if (Test-Path $buildDir) {
        Write-Host "`nCleaning build directory..." -ForegroundColor Yellow
        Remove-Item -Recurse -Force $buildDir
    }
}

# ── Step 4: Build ───────────────────────────────────────────────────────────

# Base cmake flags matching the Makefile's release-win64 target
$cmakeFlags = @(
    "-D STATIC=$(if ($Static) { 'ON' } else { 'OFF' })",
    "-G 'MSYS Makefiles'",
    "-D DEV_MODE=OFF",
    "-D MANUAL_SUBMODULES=OFF",
    "-D ARCH=x86-64",
    "-D BUILD_64=ON",
    "-D CMAKE_BUILD_TYPE=Release",
    "-D BUILD_TAG=win-x64",
    '-D CMAKE_TOOLCHAIN_FILE=../../cmake/64-bit-toolchain.cmake',
    '-D MSYS2_FOLDER=$MINGW_PREFIX/..',
    "-D MINGW=ON"
) -join " "

# Add no-miner flags
if ($Variant -eq "nominer") {
    $cmakeFlags += " -D WITH_MINING=OFF -D WITH_P2POOL=OFF -D WITH_UPDATER=OFF"
    Write-Host "`nBuilding NO-MINER variant" -ForegroundColor Green
} else {
    Write-Host "`nBuilding STANDARD variant" -ForegroundColor Green
}

$buildCmd = @"
cd '$msysRepoPath' && \
mkdir -p build/release && \
cd build/release && \
cmake $cmakeFlags ../.. && \
make -j$Jobs
"@

Invoke-Msys2 $buildCmd "CMake configure + build"

# ── Step 5: Deploy (collect DLLs) ──────────────────────────────────────────
Invoke-Msys2 "cd '$msysRepoPath/build/release' && make deploy" "Deploying (collecting runtime DLLs)"

# ── Step 6: Validate nominer build ──────────────────────────────────────────
if ($Variant -eq "nominer") {
    Write-Host "`nValidating no-miner artifact..." -ForegroundColor Yellow
    
    $binDir = Join-Path $RepoPath "build\release\bin"
    
    $p2poolFiles = Get-ChildItem -Path $binDir -Filter "p2pool*" -ErrorAction SilentlyContinue
    if ($p2poolFiles) {
        Write-Warning "FAIL: p2pool binary found in nominer build: $($p2poolFiles.Name)"
    } else {
        Write-Host "  OK: No p2pool binaries" -ForegroundColor Green
    }
    
    $salviumd = Get-ChildItem -Path $binDir -Filter "salviumd*" -ErrorAction SilentlyContinue
    if ($salviumd) {
        Write-Host "  OK: salviumd present" -ForegroundColor Green
    } else {
        Write-Warning "  NOTE: salviumd not found (expected if submodule wasn't built)"
    }
}

# ── Done ────────────────────────────────────────────────────────────────────
$binDir = Join-Path $RepoPath "build\release\bin"
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "Build complete!" -ForegroundColor Green
Write-Host "Variant:  $Variant" -ForegroundColor Green
Write-Host "Binaries: $binDir" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

# Open the bin folder
if (Test-Path $binDir) {
    Write-Host "`nOpen output folder? (Y/n): " -NoNewline
    $response = Read-Host
    if ($response -ne "n") {
        explorer.exe $binDir
    }
}