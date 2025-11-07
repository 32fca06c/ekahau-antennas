#!/bin/pwsh

if ($IsLinux) {
    $path = "$HOME/Ekahau Pro/.settings/updates/"
} elseif ($env:OS -eq 'Windows_NT' -or $IsWindows) {
    $path = "$env:userprofile\Ekahau Pro\.settings\updates\"
} elseif ($IsMacOS) {
    $path = "$HOME\Library\Ekahau Pro\.settings\updates\"
} else {
    exit 1
}

# accessPointTypes.xml
$accessPointTypes = New-Object System.Xml.XmlDocument
$accessPointTypes.AppendChild($accessPointTypes.CreateXmlDeclaration("1.0", $null, $null))
$accessPointTypes.AppendChild($accessPointTypes.CreateElement("accessPointTypes"))

$ekahau = New-Object System.Xml.XmlDocument
$ekahau.Load("https://sw.ekahau.com/download/pro/antennas/accessPointTypes.xml")
$ekahau.DocumentElement.ChildNodes | ForEach-Object { $accessPointTypes.DocumentElement.AppendChild($accessPointTypes.ImportNode($_, $true)) }

Get-ChildItem -Path $PSScriptRoot -Directory | ForEach-Object {
    $xml = Join-Path -Path $_ -ChildPath "accessPointTypes.xml"
    if (Test-Path $xml) {
        $temp = New-Object System.Xml.XmlDocument
        $temp.Load($xml)
        $temp.DocumentElement.ChildNodes | ForEach-Object { $accessPointTypes.DocumentElement.AppendChild($accessPointTypes.ImportNode($_, $true))
        }
    }
}

$sorted = $accessPointTypes.accessPointTypes.accessPointType | Sort-Object @{Expression = { $_.GetAttribute("vendor") }}, @{Expression = { $_.GetAttribute("model") }}
$accessPointTypes.DocumentElement.RemoveAll()
$sorted | ForEach-Object { $accessPointTypes.DocumentElement.AppendChild($_) }

$accessPointTypes.Save((Join-Path -Path $path -ChildPath "accessPointTypes.xml"))

# antennas.zip
$antennas = "https://sw.ekahau.com/download/pro/antennas/antennas.zip"

$antennasPath = Join-Path -Path $path -ChildPath "antennas"
$zipPath = Join-Path -Path $path -ChildPath "ekahau.zip"

Invoke-WebRequest -Uri "https://sw.ekahau.com/download/pro/antennas/antennas.zip" -OutFile $zipPath
Expand-Archive -Path $zipPath -DestinationPath $antennasPath -Force

$json = Get-ChildItem -Path $PSScriptRoot -Recurse -Filter "*.json" -File

foreach ($file in $json) {
    $destination = Join-Path -Path $antennasPath -ChildPath $file.Name
    Copy-Item -Path $file.FullName -Destination $destination -Force
}

# Windows Hotfix for JSON
if ($env:OS -eq 'Windows_NT' -or $IsWindows) {
    $allJsonFiles = Get-ChildItem -Path $antennasPath -Filter "*.json" -Recurse -File
    foreach ($file in $allJsonFiles) {
        $content = Get-Content -Path $file.FullName -Raw
        $content = $content -replace "`n", "`r`n"
        $encoding = [System.Text.Encoding]::GetEncoding(1251)
        [System.IO.File]::WriteAllText($file.FullName, $content, $encoding)
    }
}

$newZipPath = Join-Path -Path $path -ChildPath "antennas.zip"
Compress-Archive -Path "$antennasPath\*" -DestinationPath $newZipPath -Force
