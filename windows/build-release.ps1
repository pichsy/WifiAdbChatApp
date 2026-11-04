<#
.SYNOPSIS
    生成 release\ 下的 Windows 安装包（自包含单文件 exe + NSIS 安装程序）。

.DESCRIPTION
    1) dotnet publish 出 win-x64 自包含程序（目标机器无需安装 .NET）；
       原生库不塞进 exe：主程序 + 3 个原生库一起发布，程序直接从安装目录运行，
       不再把文件解压到 C:\Users\...\AppData\Local\Temp 里；
    2) 用 NSIS 编译安装程序，产物在仓库根目录的 release\。
    安装程序把文件全部装到向导里选的目录（默认 D:\Program Files\文件互传助手）；
    完成页有「创建桌面快捷方式」，默认勾选，点「完成」时才创建。

.PARAMETER Configuration
    构建配置，默认 Release。

.PARAMETER Runtime
    目标运行时，默认 win-x64。

.PARAMETER Dotnet
    dotnet 可执行文件，默认从 PATH 查找。

.PARAMETER Makensis
    makensis 可执行文件，默认从 PATH 查找（需要 NSIS 3.x Unicode 版）。

.PARAMETER SkipBuild
    跳过 dotnet publish，直接用现有的 windows\publish\release-build\ADBTypeLink.App.exe 重打安装包。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-release.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-release.ps1 -SkipBuild
#>
[CmdletBinding()]
param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64",
    [string]$Dotnet = "dotnet",
    [string]$Makensis = "makensis",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $root
$appProject = Join-Path $root "src\ADBTypeLink.App\ADBTypeLink.App.csproj"
$publishDir = Join-Path $root "publish\release-build"
$installerScript = Join-Path $root "installer\setup.nsi"
$releaseDir = Join-Path $repo "release"

function Find-Tool {
    param([string]$Name, [string]$Hint)
    if (Test-Path $Name) { return (Resolve-Path $Name).Path }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "找不到 $Name。$Hint"
}

$dotnetExe = Find-Tool $Dotnet "请先安装 .NET 8 SDK：https://dotnet.microsoft.com/download/dotnet/8.0"
$makensisExe = Find-Tool $Makensis "请先安装 NSIS 3.x（Unicode 版）：https://nsis.sourceforge.io/"

New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

if (-not $SkipBuild) {
    Write-Host "==> 发布 $Runtime 自包含单文件" -ForegroundColor Cyan
    $publishArgs = @(
        "publish", $appProject,
        "-c", $Configuration,
        "-r", $Runtime,
        "--self-contained", "true",
        "-p:PublishSingleFile=true",
        "-p:IncludeNativeLibrariesForSelfExtract=false",
        "-p:DebugType=None",
        "-p:DebugSymbols=false",
        "-o", $publishDir
    )
    & $dotnetExe @publishArgs
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish 失败（退出码 $LASTEXITCODE）" }
}

$payload = Join-Path $publishDir "ADBTypeLink.App.exe"
if (-not (Test-Path $payload)) {
    throw "未找到 $payload；请先不带 -SkipBuild 运行本脚本。"
}

Write-Host "==> 编译 NSIS 安装程序" -ForegroundColor Cyan
& $makensisExe /INPUTCHARSET UTF8 $installerScript
if ($LASTEXITCODE -ne 0) { throw "makensis 失败（退出码 $LASTEXITCODE）" }

Write-Host ""
Write-Host "生成完成：" -ForegroundColor Green
Get-ChildItem $releaseDir -Filter *.exe | ForEach-Object {
    "{0}  ({1:N1} MB)" -f $_.FullName, ($_.Length / 1MB)
}
