param(
    [string]$Hostname = "localhost"
)

$ErrorActionPreference = "Stop"
$certDirectory = Join-Path $PSScriptRoot "certs"
New-Item -ItemType Directory -Force -Path $certDirectory | Out-Null
$resolved = (Resolve-Path $certDirectory).Path

docker run --rm -v "${resolved}:/certs" alpine/openssl sh -ec @"
openssl genrsa -out /certs/ca.key 3072
openssl req -x509 -new -key /certs/ca.key -sha256 -days 3650 -out /certs/ca.crt -subj '/CN=WJ Local MQTT CA'
openssl genrsa -out /certs/server.key 3072
openssl req -new -key /certs/server.key -out /certs/server.csr -subj '/CN=$Hostname'
printf 'subjectAltName=DNS:$Hostname,DNS:host.docker.internal,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' >/tmp/server.ext
openssl x509 -req -in /certs/server.csr -CA /certs/ca.crt -CAkey /certs/ca.key -CAcreateserial -out /certs/server.crt -days 825 -sha256 -extfile /tmp/server.ext
rm /certs/server.csr /certs/ca.srl
"@

Write-Host "Development MQTT certificates created in $resolved"
Write-Host "Set MQTT_TLS_CA_PATH=$resolved\ca.crt when starting the backend."
