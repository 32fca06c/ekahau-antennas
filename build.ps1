#!/bin/pwsh

$antennas = "https://sw.ekahau.com/download/pro/antennas/antennas.zip"

######################

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

######################
$ekahau = New-Object System.Xml.XmlDocument
$ekahau.Load("https://sw.ekahau.com/download/pro/antennas/accessPointTypes.xml")
$ekahau.DocumentElement.ChildNodes | ForEach-Object { $accessPointTypes.DocumentElement.AppendChild($accessPointTypes.ImportNode($_, $true)) }

######################
Get-ChildItem -Path $PSScriptRoot -Directory | ForEach-Object {
    $xml = Join-Path -Path $_ -ChildPath "accessPointTypes.xml"
    if (Test-Path $xml) {
        $temp = New-Object System.Xml.XmlDocument
        $temp.Load($xml)
        $temp.DocumentElement.ChildNodes | ForEach-Object { $accessPointTypes.DocumentElement.AppendChild($accessPointTypes.ImportNode($_, $true))
        }
    }
}

######################
$sorted = $accessPointTypes.accessPointTypes.accessPointType | Sort-Object @{Expression = { $_.GetAttribute("vendor") }}, @{Expression = { $_.GetAttribute("model") }}
$accessPointTypes.DocumentElement.RemoveAll()
$sorted | ForEach-Object { $accessPointTypes.DocumentElement.AppendChild($_) }

######################
$accessPointTypes.Save((Join-Path -Path $path -ChildPath "accessPointTypes.xml"))

# antennas.zip

# Antennas directory and zip path
$antennasPath = Join-Path -Path $path -ChildPath "antennas"
$zipPath = Join-Path -Path $path -ChildPath "ekahau.zip"

# Download the antennas.zip file
Invoke-WebRequest -Uri "https://sw.ekahau.com/download/pro/antennas/antennas.zip" -OutFile $zipPath

# Extract the zip file
Expand-Archive -Path $zipPath -DestinationPath $antennasPath -Force

# Add all JSON files from subdirectories
$jsonFiles = Get-ChildItem -Path $PSScriptRoot -Recurse -Filter "*.json" -File

foreach ($file in $jsonFiles) {
    $destination = Join-Path -Path $antennasPath -ChildPath $file.Name
    Copy-Item -Path $file.FullName -Destination $destination -Force
}

# Create new archive
$newZipPath = Join-Path -Path $path -ChildPath "antennas.zip"
Compress-Archive -Path "$antennasPath\*" -DestinationPath $newZipPath -Force
Write-Host "Successfully created new antennas.zip at $newZipPath"
