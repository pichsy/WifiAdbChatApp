<#
.SYNOPSIS
    文件互传助手（Windows）构建脚本：Release 构建 + win-x64 / win-arm64 发布 + 冒烟测试。

.DESCRIPTION
    在 Windows 上构建并发布 Avalonia 桌面端；也支持在安装了 .NET 8 SDK 的其它平台上仅做构建与冒烟测试。
    产物：publish\win-x64\、publish\win-arm64\（自包含单文件，目标机器无需安装 .NET）。

.PARAMETER Configuration
    构建配置，默认 Release。

.PARAMETER SkipPublish
    只构建，不发布。

.PARAMETER FrameworkDependent
    发布框架依赖版本（目标机器需要安装 .NET 8 桌面运行时）。

.PARAMETER SkipSmokeTest
    跳过冒烟测试。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build.ps1 -SkipPublish -SkipSmokeTest
#>
[CmdletBinding()]
param(
    [string]$Configuration = "Release",
    [switch]$SkipPublish,
    [switch]$FrameworkDependent,
    [switch]$SkipSmokeTest
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$solution = Join-Path $root "ADBTypeLink.sln"

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Invoke-DotNet {
    param([string[]]$Arguments)
    Write-Host "dotnet $($Arguments -join ' ')" -ForegroundColor DarkGray
    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet $($Arguments -join ' ') 失败，退出码 $LASTEXITCODE"
    }
}

Push-Location $root
try {
    Write-Step "检查 .NET SDK"
    & dotnet --version
    if ($LASTEXITCODE -ne 0) {
        throw "未找到 dotnet，请先安装 .NET 8 SDK：https://dotnet.microsoft.com/download/dotnet/8.0"
    }

    Write-Step "还原依赖"
    Invoke-DotNet @("restore", $solution)

    Write-Step "构建（$Configuration）"
    Invoke-DotNet @("build", $solution, "-c", $Configuration, "--no-restore")

    if (-not $SkipSmokeTest) {
        Write-Step "冒烟测试（两个 Core 实例走真实 socket 互通）"
        Invoke-DotNet @("run", "--project", (Join-Path $root "src\ADBTypeLink.SmokeTest\ADBTypeLink.SmokeTest.csproj"), "-c", $Configuration, "--no-build")
    }

    if (-not $SkipPublish) {
        foreach ($runtime in @("win-x64", "win-arm64")) {
            Write-Step "发布桌面端 $runtime"
            $publishArgs = @(
                "publish",
                (Join-Path $root "src\ADBTypeLink.App\ADBTypeLink.App.csproj"),
                "-c", $Configuration,
                "-r", $runtime,
                "--self-contained", $(if ($FrameworkDependent) { "false" } else { "true" }),
                "-p:PublishSingleFile=true",
                "-p:IncludeNativeLibrariesForSelfExtract=true",
                "-p:DebugType=None",
                "-p:DebugSymbols=false",
                "-o", (Join-Path $root "publish\$runtime")
            )
            Invoke-DotNet $publishArgs

            Write-Step "发布联调工具 $runtime"
            $toolsArgs = @(
                "publish",
                (Join-Path $root "src\ADBTypeLink.TestPeer\ADBTypeLink.TestPeer.csproj"),
                "-c", $Configuration,
                "-r", $runtime,
                "--self-contained", "false",
                "-o", (Join-Path $root "publish\$runtime\tools")
            )
            Invoke-DotNet $toolsArgs
        }
    }

    Write-Host ""
    Write-Host "构建完成。" -ForegroundColor Green
    if (-not $SkipPublish) {
        Write-Host "可执行文件："
        Write-Host "  publish\win-x64\ADBTypeLink.App.exe"
        Write-Host "  publish\win-arm64\ADBTypeLink.App.exe"
        Write-Host "首次运行请在 Windows 安全中心 → 防火墙允许「专用网络」，详见 README.md。"
    }
}
finally {
    Pop-Location
}
