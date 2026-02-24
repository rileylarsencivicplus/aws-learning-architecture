# id.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

aws sts get-caller-identity
