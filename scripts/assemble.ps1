param(
    [string]$UpstreamUrl = 'https://github.com/bggRGjQaUbCoE/PiliPlus.git'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = Split-Path $PSScriptRoot
Push-Location $root
$patch = $null
try {
    if (git status --porcelain) {
        throw 'Run assembly in a clean, disposable checkout of the customization repository.'
    }
    if ((git rev-parse --is-shallow-repository) -ne 'false') {
        throw 'Assembly requires the full Git history for the package version code.'
    }
    $source = (git rev-parse HEAD).Trim()
    $upstream = (Get-Content upstream.lock -Raw).Trim()
    if ($upstream -cnotmatch '^[0-9a-f]{40}$') {
        throw 'upstream.lock must contain a full upstream commit SHA.'
    }

    $patch = New-TemporaryFile
    Copy-Item -LiteralPath patches/customization.patch -Destination $patch.FullName
    git fetch --no-tags $UpstreamUrl $upstream
    git -c core.autocrlf=false checkout --detach $upstream
    git -c core.autocrlf=false apply --index --3way $patch.FullName
    git diff --cached --check

    $tree = (git write-tree).Trim()
    # Keep the previous fork history and upstream history in the version count.
    $assembled = (git -c user.name=PiliPlus -c user.email=build@localhost commit-tree $tree -p $source -p $upstream -m "Assemble $source on $upstream").Trim()
    git -c core.autocrlf=false checkout --detach $assembled
    if ($env:GITHUB_ENV) {
        Add-Content -LiteralPath $env:GITHUB_ENV -Value "PILIPLUS_SOURCE_COMMIT=$source"
    }
    Write-Host "Assembled $source on $upstream"
}
finally {
    if ($patch) { Remove-Item -LiteralPath $patch.FullName }
    Pop-Location
}
