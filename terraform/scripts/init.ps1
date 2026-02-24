# init.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (Test-Path '.terraform') {
    Remove-Item -Recurse -Force '.terraform'
}

if (Test-Path '.terraform.lock.hcl') {
    Remove-Item -Force '.terraform.lock.hcl'
}

terraform init

Write-Host "Initialized for Riley's root AWS account"
