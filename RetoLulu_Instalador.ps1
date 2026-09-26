[CmdletBinding()]
param(
    [ValidateSet('Install', 'Update')]
    [string]$Mode = 'Install'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$RepoOwner = 'tecteccruz-dot'
$RepoName = 'Reto-Lulu'
$InstanceRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$CacheRoot = Join-Path $InstanceRoot '.retolulu-cache'
$StatePath = Join-Path $InstanceRoot '.retolulu-state.json'
$ManifestPath = Join-Path $InstanceRoot '.retolulu-installed-manifest.json'
$ApiHeaders = @{ 'User-Agent' = 'Reto-Lulu-Installer'; 'Accept' = 'application/vnd.github+json' }

function Write-Step([string]$Text) {
    Write-Host "`n==> $Text" -ForegroundColor Cyan
}

function Get-LatestRelease {
    $uri = "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"
    try {
        return Invoke-RestMethod -Uri $uri -Headers $ApiHeaders -UseBasicParsing
    }
    catch {
        throw "No se pudo consultar la ultima version de Reto Lulu. $($_.Exception.Message)"
    }
}

function Get-ReleaseInfo($Release) {
    $version = ([string]$Release.tag_name).TrimStart('v', 'V')
    $zip = @($Release.assets | Where-Object { $_.name -eq "Reto-Lulu-$version.zip" }) | Select-Object -First 1
    $sha = @($Release.assets | Where-Object { $_.name -eq "Reto-Lulu-$version.zip.sha256" }) | Select-Object -First 1
    if (-not $zip -or -not $sha) {
        throw "La version $version no contiene los archivos esperados de la build."
    }
    [pscustomobject]@{ Version = $version; Zip = $zip; Sha = $sha }
}

function Download-File([string]$Uri, [string]$Destination, [string]$Label) {
    $parent = Split-Path -Parent $Destination
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp = "$Destination.part"
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue

    $client = New-Object Net.Http.HttpClient
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('Reto-Lulu-Installer')
    try {
        $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode() | Out-Null
        $total = $response.Content.Headers.ContentLength
        $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $output = [IO.File]::Open($temp, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $buffer = New-Object byte[] (1MB)
            [long]$received = 0
            $lastPercent = -1
            while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $output.Write($buffer, 0, $read)
                $received += $read
                if ($total -gt 0) {
                    $percent = [Math]::Min(100, [int](($received * 100) / $total))
                    if ($percent -ne $lastPercent) {
                        Write-Progress -Activity $Label -Status "$percent%" -PercentComplete $percent
                        $lastPercent = $percent
                    }
                }
            }
        }
        finally {
            if ($output) { $output.Dispose() }
            if ($input) { $input.Dispose() }
            Write-Progress -Activity $Label -Completed
        }
        Move-Item -LiteralPath $temp -Destination $Destination -Force
    }
    finally {
        $client.Dispose()
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-JsonFile($Value, [string]$Path) {
    $json = $Value | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Resolve-SafePath([string]$RelativePath, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "Ruta invalida en la build: $RelativePath"
    }
    $normalized = $RelativePath.Replace('/', '\')
    $full = [IO.Path]::GetFullPath((Join-Path $Root $normalized))
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Ruta fuera de la instancia: $RelativePath"
    }
    return $full
}

function Expand-SafeZip([string]$Archive, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entry in $zip.Entries) {
            $target = Resolve-SafePath -RelativePath $entry.FullName -Root $Destination
            if ([string]::IsNullOrEmpty($entry.Name)) {
                [IO.Directory]::CreateDirectory($target) | Out-Null
                continue
            }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Ask-RecommendedOptions([bool]$DefaultValue) {
    $defaultText = if ($DefaultValue) { 'S' } else { 'N' }
    while ($true) {
        $answer = (Read-Host "Aplicar la configuracion recomendada de Reto Lulu? [S/N] (predeterminado: $defaultText)").Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultValue }
        if ($answer -match '^(s|si|sí|y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
        Write-Host 'Escribe S o N.' -ForegroundColor Yellow
    }
}

function Test-InstalledFiles($Manifest, [bool]$ApplyOptions) {
    $problems = New-Object Collections.Generic.List[object]
    foreach ($file in @($Manifest.files)) {
        $relative = [string]$file.path
        if (-not $ApplyOptions -and $relative -ieq 'options.txt') { continue }
        $target = Resolve-SafePath -RelativePath $relative -Root $InstanceRoot
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $problems.Add([pscustomobject]@{ File = $file; Reason = 'faltante' })
            continue
        }
        if ((Get-Sha256 $target) -ne ([string]$file.sha256).ToLowerInvariant()) {
            $problems.Add([pscustomobject]@{ File = $file; Reason = 'modificado' })
        }
    }
    return @($problems)
}

function Install-Build($Info, [bool]$ApplyOptions, $PreviousManifest) {
    $versionCache = Join-Path $CacheRoot $Info.Version
    $archive = Join-Path $versionCache $Info.Zip.name
    $shaFile = Join-Path $versionCache $Info.Sha.name

    [IO.Directory]::CreateDirectory($versionCache) | Out-Null
    Download-File -Uri $Info.Sha.browser_download_url -Destination $shaFile -Label 'Descargando verificacion'
    $expectedHash = ((Get-Content -LiteralPath $shaFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    if ($expectedHash -notmatch '^[a-f0-9]{64}$') { throw 'La suma SHA256 publicada no es valida.' }

    $needArchive = -not (Test-Path -LiteralPath $archive -PathType Leaf)
    if (-not $needArchive) { $needArchive = (Get-Sha256 $archive) -ne $expectedHash }
    if ($needArchive) {
        Write-Step "Descargando Reto Lulu $($Info.Version)"
        Download-File -Uri $Info.Zip.browser_download_url -Destination $archive -Label "Reto Lulu $($Info.Version)"
    }
    if ((Get-Sha256 $archive) -ne $expectedHash) { throw 'La build descargada no paso la verificacion SHA256.' }

    Write-Step 'Extrayendo la build en la cache'
    $extractRoot = Join-Path $versionCache 'extraido'
    Expand-SafeZip -Archive $archive -Destination $extractRoot
    $buildManifestPath = Join-Path $extractRoot '.retolulu-build.json'
    $payloadRoot = Join-Path $extractRoot 'payload'
    $manifest = Read-JsonFile $buildManifestPath
    if (-not $manifest -or -not (Test-Path -LiteralPath $payloadRoot -PathType Container)) {
        throw 'La build no contiene un manifiesto valido.'
    }
    if ([string]$manifest.version -ne [string]$Info.Version) {
        throw 'La version interna de la build no coincide con la Release.'
    }

    if ($PreviousManifest) {
        $newPaths = @{}
        foreach ($file in @($manifest.files)) { $newPaths[[string]$file.path] = $true }
        foreach ($oldFile in @($PreviousManifest.files)) {
            $oldRelative = [string]$oldFile.path
            if (-not $ApplyOptions -and $oldRelative -ieq 'options.txt') { continue }
            if (-not $newPaths.ContainsKey($oldRelative)) {
                $oldTarget = Resolve-SafePath -RelativePath $oldRelative -Root $InstanceRoot
                if (Test-Path -LiteralPath $oldTarget -PathType Leaf) { Remove-Item -LiteralPath $oldTarget -Force }
            }
        }
    }

    Write-Step 'Aplicando archivos'
    $files = @($manifest.files)
    $index = 0
    foreach ($file in $files) {
        $index++
        $relative = [string]$file.path
        if (-not $ApplyOptions -and $relative -ieq 'options.txt') { continue }
        $source = Resolve-SafePath -RelativePath $relative -Root $payloadRoot
        $target = Resolve-SafePath -RelativePath $relative -Root $InstanceRoot
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Falta un archivo en la build: $relative" }
        if ((Get-Sha256 $source) -ne ([string]$file.sha256).ToLowerInvariant()) { throw "Archivo dañado en la build: $relative" }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
        $percent = [int](($index * 100) / [Math]::Max(1, $files.Count))
        Write-Progress -Activity 'Instalando Reto Lulu' -Status "$percent%" -PercentComplete $percent
    }
    Write-Progress -Activity 'Instalando Reto Lulu' -Completed

    Save-JsonFile $manifest $ManifestPath
    Save-JsonFile ([ordered]@{
        installedVersion = [string]$Info.Version
        applyRecommendedOptions = $ApplyOptions
        installedAt = (Get-Date).ToUniversalTime().ToString('o')
    }) $StatePath
    return $manifest
}

function Repair-Build($Info, $Manifest, [bool]$ApplyOptions, $Problems) {
    if (@($Problems).Count -eq 0) {
        Write-Host 'Todos los archivos de Reto Lulu estan correctos.' -ForegroundColor Green
        return
    }
    Write-Host "Se repararan $(@($Problems).Count) archivo(s) faltantes o modificados." -ForegroundColor Yellow
    Install-Build -Info $Info -ApplyOptions $ApplyOptions -PreviousManifest $Manifest | Out-Null
}

try {
    Clear-Host
    Write-Host '========================================' -ForegroundColor DarkCyan
    Write-Host '              RETO LULU' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor DarkCyan
    Write-Host "Carpeta de destino: $InstanceRoot"
    [IO.Directory]::CreateDirectory($CacheRoot) | Out-Null

    Write-Step 'Consultando la ultima version'
    $release = Get-LatestRelease
    $info = Get-ReleaseInfo $release
    $state = Read-JsonFile $StatePath
    $installedManifest = Read-JsonFile $ManifestPath

    if ($Mode -eq 'Install') {
        Write-Host "Version disponible: $($info.Version)"
        Write-Step 'Preparando la instalacion'
        $versionCache = Join-Path $CacheRoot $info.Version
        [IO.Directory]::CreateDirectory($versionCache) | Out-Null
        $shaPath = Join-Path $versionCache $info.Sha.name
        $zipPath = Join-Path $versionCache $info.Zip.name
        Download-File -Uri $info.Sha.browser_download_url -Destination $shaPath -Label 'Descargando verificacion'
        $expected = ((Get-Content -LiteralPath $shaPath -Raw).Trim() -split '\s+')[0]
        if (-not (Test-Path -LiteralPath $zipPath) -or (Get-Sha256 $zipPath) -ne $expected.ToLowerInvariant()) {
            Download-File -Uri $info.Zip.browser_download_url -Destination $zipPath -Label "Descargando Reto Lulu $($info.Version)"
        }
        $applyOptions = Ask-RecommendedOptions -DefaultValue $true
        Install-Build -Info $info -ApplyOptions $applyOptions -PreviousManifest $installedManifest | Out-Null
        Write-Host "`nReto Lulu $($info.Version) se instalo correctamente." -ForegroundColor Green
    }
    else {
        if (-not $state -or -not $installedManifest) {
            Write-Host 'No se encontro una instalacion registrada. Se aplicara la ultima build.' -ForegroundColor Yellow
            $applyOptions = Ask-RecommendedOptions -DefaultValue $true
            Install-Build -Info $info -ApplyOptions $applyOptions -PreviousManifest $installedManifest | Out-Null
        }
        elseif ([string]$state.installedVersion -ne [string]$info.Version) {
            Write-Host "Nueva version: $($state.installedVersion) -> $($info.Version)" -ForegroundColor Yellow
            $applyOptions = Ask-RecommendedOptions -DefaultValue ([bool]$state.applyRecommendedOptions)
            Install-Build -Info $info -ApplyOptions $applyOptions -PreviousManifest $installedManifest | Out-Null
        }
        else {
            Write-Host "Ya tienes la version $($info.Version). Comprobando archivos..."
            $applyOptions = [bool]$state.applyRecommendedOptions
            $problems = Test-InstalledFiles -Manifest $installedManifest -ApplyOptions $applyOptions
            Repair-Build -Info $info -Manifest $installedManifest -ApplyOptions $applyOptions -Problems $problems
        }
        Write-Host "`nReto Lulu esta actualizado y verificado." -ForegroundColor Green
    }
    exit 0
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
