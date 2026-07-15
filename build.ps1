param(
    [switch]$Debug
)

Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

Write-Host "Ekahau Antennas 3"
if ($Debug) { Write-Host "[INFO] debug mode: using only local vendor data (no downloads, no fallback)" }
Write-Host ""

$XmlUrl   = "https://sw.ekahau.com/download/pro/accessPointAndAntenna/accessPointTypes.xml"
$ZipUrl   = "https://sw.ekahau.com/download/pro/accessPointAndAntenna/antennas.zip"
$UserAgent = "Java/21.0.8"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Radio attributes that explicitly name an antenna JSON (used by reference checks).
$DefaultAntennaAttrs = @("defaultAntenna24", "defaultAntenna5", "defaultAntenna6", "defaultAntennaBluetooth")

if ($IsLinux -or $IsMacOS) {
    $LineEnding      = "`n"
    $LineEndingLabel = "LF"
} else {
    $LineEnding      = "`r`n"
    $LineEndingLabel = "CRLF"
}

# ============================================================
# Generic helpers
# ============================================================

function New-WritableFile {
    param([string]$Path, [int]$TimeoutSec = 60)
    $deadline  = (Get-Date).AddSeconds($TimeoutSec)
    $announced = $false
    while ($true) {
        try {
            return [System.IO.File]::Create($Path)
        } catch {
            if ((Get-Date) -ge $deadline) {
                Write-Host "[WARN] timeout (${TimeoutSec}s) waiting for $Path to be writable"
                exit 1
            }
            if (-not $announced) {
                Write-Host "[WAIT] $Path is locked, retrying for up to ${TimeoutSec}s..."
                $announced = $true
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Test-Utf8Format {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    try {
        $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
        [void]$utf8Strict.GetString($bytes)
        $isUtf8 = $true
    } catch {
        $isUtf8 = $false
    }

    $hasCr = $false; $hasLf = $false; $hasBareLf = $false
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0D) { $hasCr = $true }
        elseif ($bytes[$i] -eq 0x0A) {
            $hasLf = $true
            if ($i -eq 0 -or $bytes[$i - 1] -ne 0x0D) { $hasBareLf = $true }
        }
    }

    $issues = @()
    if (-not $isUtf8) { $issues += "not UTF-8" }
    if ($hasBom)      { $issues += "has BOM" }
    if (-not $hasLf -and -not $hasCr) {
        $issues += "no line breaks"
    } elseif ($LineEndingLabel -eq 'CRLF') {
        if ($hasBareLf) { $issues += "not CRLF (LF found)" }
    } else {
        if ($hasCr) { $issues += "not LF (CR found)" }
    }

    [pscustomobject]@{ Ok = ($issues.Count -eq 0); Issues = $issues }
}

function ConvertTo-LineEnding {
    param([string]$Text)
    $Text = $Text -replace "`r`n", "`n"
    $Text = $Text -replace "`r",   "`n"
    if ($LineEnding -eq "`r`n") {
        $Text = $Text -replace "`n", "`r`n"
    }
    return $Text
}

function Repair-JsonLeadingZeros {
    # Drop redundant leading zeros from numbers (e.g. 00.0 -> 0.0) so the bundled
    # JSON is spec-valid. String contents are never touched: the alternation
    # matches a whole string literal first (and returns it verbatim), so only
    # numbers in value position are rewritten. Exponents (1e-05) and normal
    # numbers (100.0) are left alone by the two look-behinds. Source files are not
    # modified - only the copy written into antennas.zip.
    param([string]$Text)
    $pattern = '("(?:[^"\\]|\\.)*")|((?<![0-9.eE])(?<![eE][+-])0+(?=[0-9]))'
    return [regex]::Replace($Text, $pattern, {
        param($m)
        if ($m.Groups[1].Success) { $m.Value } else { '' }
    })
}

function Repair-JsonMounting {
    # Replace an out-of-enum defaultMounting value with UNKNOWN so the bundled JSON
    # is spec-valid (the Mounting enum is CEILING / WALL / FLOOR / UNKNOWN; anything
    # else is not a member). The "defaultMounting" key anchors the match, so string
    # values are untouched. Source files are not modified - only the antennas.zip copy.
    param([string]$Text)
    return [regex]::Replace($Text, '("defaultMounting"\s*:\s*")([^"]*)(")', {
        param($m)
        if (@('CEILING', 'WALL', 'FLOOR', 'UNKNOWN') -contains $m.Groups[2].Value) { $m.Value }
        else { $m.Groups[1].Value + 'UNKNOWN' + $m.Groups[3].Value }
    })
}

function Get-OutputDir {
    if ($IsLinux)   { return "$HOME/Ekahau Pro/.settings/updates" }
    if ($IsMacOS)   { return "$HOME/Library/Ekahau Pro/.settings/updates" }
    if ($env:OS -eq 'Windows_NT' -or $IsWindows) {
        return (Join-Path $env:USERPROFILE "Ekahau Pro\.settings\updates")
    }
    throw "Unknown OS"
}

# ============================================================
# Read antenna zip into a map (entry name -> json text)
# ============================================================

function Read-AntennaArchive {
    param($Archive, $Map)
    foreach ($entry in $Archive.Entries) {
        $s = $entry.Open()
        try {
            $sr = New-Object System.IO.StreamReader($s, $Utf8NoBom)
            try {
                $Map[$entry.FullName] = $sr.ReadToEnd()
            } finally {
                $sr.Close()
            }
        } finally {
            $s.Close()
        }
    }
}

# ============================================================
# Downloads with local fallback
# ============================================================

function Get-FactoryAccessPointTypes {
    param([string]$Url, [string]$FallbackPath)

    $xml = New-Object System.Xml.XmlDocument
    [void]$xml.AppendChild($xml.CreateXmlDeclaration("1.0", $null, $null))

    try {
        $r = Invoke-WebRequest -Uri $Url -Headers @{ "User-Agent" = $UserAgent } -UseBasicParsing -ErrorAction Stop
        $xml.LoadXml($r.Content)
        return $xml
    } catch {
        Write-Host "[WARN] accessPointTypes.xml download failed: $($_.Exception.Message)"
    }

    if (Test-Path -LiteralPath $FallbackPath) {
        $xml.Load($FallbackPath)
        Write-Host "[INFO] using local fallback $FallbackPath"
    } else {
        Write-Host "[WARN] no local fallback at $FallbackPath, continuing with empty root"
        [void]$xml.AppendChild($xml.CreateElement("accessPointTypes"))
    }
    return $xml
}

function Get-FactoryAntennas {
    param([string]$Url, [string]$FallbackPath, $Map)

    $tmpZip = $null
    try {
        $tmpZip = [System.IO.Path]::GetTempFileName()
        Invoke-WebRequest -Uri $Url -Headers @{ "User-Agent" = $UserAgent } -OutFile $tmpZip -UseBasicParsing -ErrorAction Stop
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tmpZip)
        try {
            Read-AntennaArchive -Archive $zip -Map $Map
        } finally {
            $zip.Dispose()
        }
        return
    } catch {
        Write-Host "[WARN] antennas.zip download/read failed: $($_.Exception.Message)"
    } finally {
        if ($tmpZip -and (Test-Path -LiteralPath $tmpZip)) {
            Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath $FallbackPath) {
        $fs = [System.IO.File]::Open($FallbackPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
            try {
                Read-AntennaArchive -Archive $zip -Map $Map
            } finally {
                $zip.Dispose()
            }
        } finally {
            $fs.Close()
        }
        Write-Host "[INFO] using local fallback $FallbackPath"
    } else {
        Write-Host "[WARN] no local fallback at $FallbackPath, continuing with vendor antennas only"
    }
}

# ============================================================
# Vendor processing
# ============================================================

function Read-VendorAccessPointTypes {
    param([string]$Path)
    $content = [System.IO.File]::ReadAllText($Path, $Utf8NoBom)
    $content = $content -replace '^\s*<\?xml[^>]*\?>\s*', ''
    $content = $content -replace '<accessPointTypes\b[^>]*>', ''
    $content = $content -replace '</accessPointTypes\s*>', ''
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml("<__root>$content</__root>")
    return $doc
}

function Merge-AccessPointTypes {
    param([System.Xml.XmlDocument]$Target, [System.Xml.XmlDocument]$Source)
    foreach ($ap in $Source.SelectNodes("//accessPointType")) {
        $imported = $Target.ImportNode($ap, $true)
        [void]$Target.DocumentElement.AppendChild($imported)
    }
}

function Show-VendorXmlEncoding {
    param([string]$Path, [string]$Label)
    $c = Test-Utf8Format -Path $Path
    if (-not $c.Ok) {
        Write-Host "[WARN] ${Label}: $($c.Issues -join ', ')"
    }
}

function Show-VendorAntennaReferences {
    param([System.Xml.XmlDocument]$VendorXml, [string]$AntennasDir, [string]$VendorName)
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($ap in $VendorXml.SelectNodes("//accessPointType")) {
        $vendor = $ap.GetAttribute('vendor')
        $model  = $ap.GetAttribute('model')
        foreach ($radio in $ap.SelectNodes("radioType")) {
            foreach ($attr in $DefaultAntennaAttrs) {
                $name = $radio.GetAttribute($attr)
                if (-not $name) { continue }
                $antennaFile = Join-Path $AntennasDir "$name.json"
                if (-not (Test-Path -LiteralPath $antennaFile)) {
                    $missing.Add("$vendor $model -> $name")
                }
            }
        }
    }
    if ($missing.Count -gt 0) {
        Write-Host "[WARN] ${VendorName}: $($missing.Count) missing antenna file(s)"
        foreach ($m in $missing) { Write-Host "       $m" }
    }
}

function Get-ReferencedAntennaNames {
    param([System.Xml.XmlDocument]$Xml)
    $names = New-Object System.Collections.Generic.HashSet[string]
    foreach ($ap in $Xml.SelectNodes("//accessPointType")) {
        $vendor = $ap.GetAttribute('vendor')
        $model  = $ap.GetAttribute('model')
        foreach ($radio in $ap.SelectNodes("radioType")) {
            # Explicit references via defaultAntenna* attributes
            foreach ($attr in $DefaultAntennaAttrs) {
                $name = $radio.GetAttribute($attr)
                if ($name) { [void]$names.Add($name) }
            }
            # Implicit reference by Ekahau naming convention: "{vendor} {model} {bandSuffix}"
            if (-not ($vendor -and $model)) { continue }
            $tech      = $radio.GetAttribute('technology')
            $radioTech = $radio.GetAttribute('radioTechnology')
            $band      = $radio.GetAttribute('frequencyBand')
            $bandSuffix = if ($radioTech -eq 'bluetooth' -or $tech -eq 'bluetooth') {
                'BLE'
            } else {
                switch ($band) {
                    '2.4'   { '2.4GHz' }
                    '5'     { '5GHz' }
                    '6'     { '6GHz' }
                    default { '' }
                }
            }
            if ($bandSuffix) {
                [void]$names.Add("$vendor $model $bandSuffix")
            }
        }
    }
    return $names
}

function Show-VendorOrphanInternalAntennas {
    param([string]$AntennasDir, [string]$VendorName, $ReferencedNames)
    if (-not (Test-Path -LiteralPath $AntennasDir)) { return }
    $orphans = New-Object System.Collections.Generic.List[string]
    foreach ($jsonFile in Get-ChildItem -LiteralPath $AntennasDir -Filter "*.json" -File) {
        $antName = [System.IO.Path]::GetFileNameWithoutExtension($jsonFile.Name)
        try {
            $j = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($jsonFile.FullName, $Utf8NoBom)) -ErrorAction Stop
        } catch { continue }
        if ($j.apCoupling -ne 'INTERNAL_ANTENNA') { continue }
        if (-not $ReferencedNames.Contains($antName)) { $orphans.Add($antName) }
    }
    if ($orphans.Count -gt 0) {
        Write-Host "[WARN] ${VendorName}: $($orphans.Count) INTERNAL_ANTENNA not referenced by any accessPointType"
        foreach ($o in $orphans) { Write-Host "       $o" }
    }
}

function Show-VendorAntennaJsonEncoding {
    param([string]$AntennasDir, [string]$VendorName)
    if (-not (Test-Path -LiteralPath $AntennasDir)) { return }
    $jsonFiles = Get-ChildItem -LiteralPath $AntennasDir -Filter "*.json" -File
    $bad = 0
    foreach ($jsonFile in $jsonFiles) {
        if (-not (Test-Utf8Format -Path $jsonFile.FullName).Ok) { $bad++ }
    }
    if ($bad -gt 0) {
        Write-Host "[WARN] ${VendorName}\antennas\*.json: $bad / $($jsonFiles.Count) not UTF-8 $LineEndingLabel"
    }
}

function Test-JsonStrict {
    param([string]$Text)
    # ConvertFrom-Json in PS 5.1 (JavaScriptSerializer) is lenient about leading-zero
    # numbers and trailing commas — strip string contents first, then regex-check.
    $stripped = [regex]::Replace($Text, '"(?:[^"\\]|\\.)*"', '""')
    $issues = New-Object System.Collections.Generic.List[string]
    if ($stripped -match '(?<![0-9.eE])0[0-9]') { $issues.Add("leading-zero number") }
    if ($stripped -match ',\s*[}\]]')           { $issues.Add("trailing comma") }
    return $issues
}

function Show-VendorAntennaJsonSyntax {
    param([string]$AntennasDir, [string]$VendorName)
    if (-not (Test-Path -LiteralPath $AntennasDir)) { return }
    $jsonFiles = Get-ChildItem -LiteralPath $AntennasDir -Filter "*.json" -File
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($jsonFile in $jsonFiles) {
        $text = [System.IO.File]::ReadAllText($jsonFile.FullName, $Utf8NoBom)
        $reason = $null
        $strictIssues = Test-JsonStrict -Text $text
        if ($strictIssues.Count -gt 0) {
            $reason = $strictIssues -join ', '
        } else {
            try {
                $null = ConvertFrom-Json -InputObject $text -ErrorAction Stop
            } catch {
                $reason = 'parse error'
            }
        }
        if ($reason) { $bad.Add("$($jsonFile.Name) ($reason)") }
    }
    if ($bad.Count -gt 0) {
        Write-Host "[WARN] ${VendorName}\antennas\*.json: $($bad.Count) / $($jsonFiles.Count) JSON syntax errors"
        foreach ($b in $bad) { Write-Host "       $b" }
    }
}

# ============================================================
# Dedup, sort, save
# ============================================================

function Invoke-DedupAndSort {
    param([System.Xml.XmlDocument]$Xml)
    $nodes = @($Xml.DocumentElement.SelectNodes("accessPointType"))
    $dedup = @{}
    foreach ($n in $nodes) {
        $key = "$($n.GetAttribute('vendor'))|$($n.GetAttribute('model'))"
        $dedup[$key] = $n
    }
    $removed = $nodes.Count - $dedup.Count
    $sorted = @($dedup.Values) | Sort-Object `
        @{ Expression = { $_.GetAttribute("vendor") } }, `
        @{ Expression = { $_.GetAttribute("model") } }
    foreach ($n in $nodes)  { [void]$Xml.DocumentElement.RemoveChild($n) }
    foreach ($n in $sorted) { [void]$Xml.DocumentElement.AppendChild($n) }
    if ($removed -gt 0) {
        Write-Host "[INFO] deduplicated: $removed duplicate (vendor + model) entries removed"
    }
}

function Save-AccessPointTypesXml {
    param([System.Xml.XmlDocument]$Xml, [string]$Path)

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding           = $Utf8NoBom
    $settings.Indent             = $true
    $settings.IndentChars        = "  "
    $settings.NewLineChars       = $LineEnding
    $settings.NewLineHandling    = [System.Xml.NewLineHandling]::Replace
    $settings.OmitXmlDeclaration = $true

    $fs = New-WritableFile -Path $Path
    try {
        $headerBytes = $Utf8NoBom.GetBytes("<?xml version=`"1.0`"?>$LineEnding")
        $fs.Write($headerBytes, 0, $headerBytes.Length)
        $writer = [System.Xml.XmlWriter]::Create($fs, $settings)
        try {
            $Xml.DocumentElement.WriteTo($writer)
        } finally {
            $writer.Close()
        }
    } finally {
        $fs.Close()
    }
}

function Save-AntennasZip {
    param($JsonMap, [string]$Path)
    $fs = New-WritableFile -Path $Path
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($name in $JsonMap.Keys) {
                $text  = ConvertTo-LineEnding -Text (Repair-JsonMounting -Text (Repair-JsonLeadingZeros -Text $JsonMap[$name]))
                $bytes = $Utf8NoBom.GetBytes($text)
                $entry = $zip.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
                $es = $entry.Open()
                try {
                    $es.Write($bytes, 0, $bytes.Length)
                } finally {
                    $es.Close()
                }
            }
        } finally {
            $zip.Dispose()
        }
    } finally {
        $fs.Close()
    }
}

# ============================================================
# Main
# ============================================================

$root       = $PSScriptRoot
$outDir     = Get-OutputDir
$outXmlPath = Join-Path $outDir "accessPointTypes.xml"
$outZipPath = Join-Path $outDir "antennas.zip"
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

if ($Debug) {
    $xml = New-Object System.Xml.XmlDocument
    [void]$xml.AppendChild($xml.CreateXmlDeclaration("1.0", $null, $null))
    [void]$xml.AppendChild($xml.CreateElement("accessPointTypes"))
} else {
    $xml = Get-FactoryAccessPointTypes -Url $XmlUrl -FallbackPath $outXmlPath
}

# Enumerate vendor folders once; reused by every per-vendor pass below.
$vendorDirs = @(Get-ChildItem -Path $root -Directory)

foreach ($vendorDir in $vendorDirs) {
    $vendorName    = $vendorDir.Name
    $vendorXmlPath = Join-Path $vendorDir.FullName "accessPointTypes.xml"
    if (-not (Test-Path -LiteralPath $vendorXmlPath)) { continue }

    Show-VendorXmlEncoding -Path $vendorXmlPath -Label "$vendorName\accessPointTypes.xml"

    $vendorXml = $null
    try {
        $vendorXml = Read-VendorAccessPointTypes -Path $vendorXmlPath
    } catch {
        Write-Host "[WARN] $vendorName\accessPointTypes.xml: XML syntax error: $($_.Exception.Message)"
    }
    if ($vendorXml) {
        Merge-AccessPointTypes -Target $xml -Source $vendorXml
    }

    $antennasDir = Join-Path $vendorDir.FullName "antennas"
    if ($vendorXml) {
        Show-VendorAntennaReferences -VendorXml $vendorXml -AntennasDir $antennasDir -VendorName $vendorName
    }
    Show-VendorAntennaJsonEncoding -AntennasDir $antennasDir -VendorName $vendorName
    Show-VendorAntennaJsonSyntax   -AntennasDir $antennasDir -VendorName $vendorName
}

Invoke-DedupAndSort -Xml $xml

# After merge: verify each vendor's INTERNAL_ANTENNA JSONs are referenced by some AP
$referenced = Get-ReferencedAntennaNames -Xml $xml
foreach ($vendorDir in $vendorDirs) {
    $antennasDir = Join-Path $vendorDir.FullName "antennas"
    Show-VendorOrphanInternalAntennas -AntennasDir $antennasDir -VendorName $vendorDir.Name -ReferencedNames $referenced
}

Save-AccessPointTypesXml -Xml $xml -Path $outXmlPath
$check = Test-Utf8Format -Path $outXmlPath
$total = $xml.DocumentElement.ChildNodes.Count
if ($check.Ok) {
    Write-Host "[INFO] saved ${outXmlPath} ($total accessPointType nodes)"
} else {
    Write-Host "[WARN] ${outXmlPath}: $($check.Issues -join ', ')"
}

$jsonMap = [ordered]@{}
if (-not $Debug) {
    Get-FactoryAntennas -Url $ZipUrl -FallbackPath $outZipPath -Map $jsonMap
}
$factoryCount    = $jsonMap.Count
$vendorOverrides = 0
$vendorAdded     = 0
foreach ($vendorDir in $vendorDirs) {
    $antennasDir = Join-Path $vendorDir.FullName "antennas"
    if (-not (Test-Path -LiteralPath $antennasDir)) { continue }
    foreach ($jsonFile in Get-ChildItem -LiteralPath $antennasDir -Filter "*.json" -File) {
        $text = [System.IO.File]::ReadAllText($jsonFile.FullName, $Utf8NoBom)
        if ($jsonMap.Contains($jsonFile.Name)) { $vendorOverrides++ } else { $vendorAdded++ }
        $jsonMap[$jsonFile.Name] = $text
    }
}

Save-AntennasZip -JsonMap $jsonMap -Path $outZipPath
Write-Host "[INFO] saved ${outZipPath} ($($jsonMap.Count) JSONs: factory=$factoryCount, vendor added=$vendorAdded, vendor overrides=$vendorOverrides)"

Write-Host ""
Write-Host "Thanks for using the script!"
Start-Sleep -Seconds 5
