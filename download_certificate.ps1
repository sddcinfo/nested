$VIServer = "vcsa.hostname"

# Required to ingore SSL Warnings
if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type)
{
	add-type -TypeDefinition  @"
		using System.Net;
		using System.Security.Cryptography.X509Certificates;
		public class TrustAllCertsPolicy : ICertificatePolicy {
			public bool CheckValidationResult(
				ServicePoint srvPoint, X509Certificate certificate,
				WebRequest request, int certificateProblem) {
				return true;
			}
	    }
"@
}

$DOWNLOAD_PATH=[Environment]::GetFolderPath("Desktop")
$DOWNLOAD_FILE_NAME="cert.zip"
$DOWNLOAD_FILE_PATH="$DOWNLOAD_PATH\$DOWNLOAD_FILE_NAME"
$EXTRACTED_CERTS_PATH="$DOWNLOAD_PATH\certs"
$VC_CERT_DOWNLOAD_URL="https://"+$VIServer+"/certs/download.zip"

[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
		
$webclient = New-Object System.Net.WebClient
$webclient.DownloadFile("$VC_CERT_DOWNLOAD_URL","$DOWNLOAD_FILE_PATH")

# Extracting SSL Certificate zip file
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($DOWNLOAD_FILE_PATH, "$DOWNLOAD_PATH")

# Find SSL certificates ending with .crt
$file = get-childitem $EXTRACTED_CERTS_PATH\ -recurse | where {$_.extension -eq ".crt"} | % { $_.FullName }
Import-Certificate -FilePath $file -CertStoreLocation Cert:\CurrentUser\Root

if (Test-Path $DOWNLOAD_FILE_PATH) {
	Write-Host "Cleaning up, deleting $DOWNLOAD_FILE_PATH"
	Remove-Item $DOWNLOAD_FILE_PATH
}
if (Test-Path $EXTRACTED_CERTS_PATH) {
	Write-Host "Cleaning up, deleting $EXTRACTED_CERTS_PATH"
	Remove-Item -Recurse -Force $EXTRACTED_CERTS_PATH
}


