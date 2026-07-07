<# 
  install-run-docker.ps1
  ------------------------------------------------------------
  Project: bpdi

  Stack:
  - n8n (SQLite, unchanged)
  - PostgreSQL (customer data only)
  - smtp4dev (SMTP + IMAP dev mail server)
  - Roundcube (mail client)

  All containers are grouped under Docker Compose project: bpdi
#>

[CmdletBinding()]
param(
  [string]$Root = "C:\workspace\n8n",
  [int]$Port = 5680,

  # PostgreSQL host port (0 = not exposed)
  [int]$CustomerPgPort = 5433,

  # smtp4dev ports (0 = not exposed)
  [int]$Smtp4devWebPort  = 5001,
  [int]$Smtp4devSmtpPort = 2525,
  [int]$Smtp4devImapPort = 8143,

  # Roundcube UI port
  [int]$RoundcubePort = 8081,

  # Qdrant ports (0 = not exposed)
  [int]$QdrantHttpPort = 6333,
  [int]$QdrantGrpcPort = 6334,

  # Opt-in reset to re-initialize customer Postgres (fixes pg_hba / TLS mismatch)
  [switch]$ResetCustomerPostgres
)

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

function New-RandomSafeString {
  param([int]$Length = 24)
  $chars = (
    [char[]]"abcdefghijklmnopqrstuvwxyz" +
    [char[]]"ABCDEFGHIJKLMNOPQRSTUVWXYZ" +
    [char[]]"0123456789_-"
  )
  -join (1..$Length | ForEach-Object { $chars | Get-Random })
}

function Assert-Running($name) {
  $state = docker inspect -f "{{.State.Status}}" $name 2>$null
  if ($state -ne "running") {
    Write-Host "`n❌ Container '$name' failed. Logs:" -ForegroundColor Red
    docker logs --tail 200 $name
    exit 1
  }
}

function Get-EnvValue {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Key
  )
  if (-not (Test-Path $Path)) { return $null }

  foreach ($line in (Get-Content $Path -ErrorAction SilentlyContinue)) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*$') { continue }
    if ($line -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*)\s*$") {
      return $Matches[1].Trim()
    }
  }
  return $null
}

function Container-Exists {
  param([Parameter(Mandatory=$true)][string]$Name)
  $exists = docker ps -a --format "{{.Names}}" 2>$null | Where-Object { $_ -eq $Name }
  return [bool]$exists
}

function Wait-Running {
  param(
    [Parameter(Mandatory=$true)][string]$ContainerName,
    [Parameter(Mandatory=$true)][string]$ServiceName,
    [int]$TimeoutSeconds = 90
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

  while ((Get-Date) -lt $deadline) {
    $id = docker ps -a --filter "name=^/$ContainerName$" --format "{{.ID}}" 2>$null
    if ($id) {
      $state = docker inspect -f "{{.State.Status}}" $ContainerName 2>$null
      if ($state -eq "running") { return }

      if ($state -eq "exited" -or $state -eq "dead") {
        Write-Host "`n❌ Container '$ContainerName' is '$state'." -ForegroundColor Red
        Write-Host "`n--- docker compose ps ---" -ForegroundColor Yellow
        docker compose ps
        Write-Host "`n--- docker compose logs ($ServiceName) ---" -ForegroundColor Yellow
        docker compose logs --tail 200 $ServiceName
        exit 1
      }
    }
    Start-Sleep 2
  }

  Write-Host "`n❌ Timeout waiting for container '$ContainerName' to be running." -ForegroundColor Red
  Write-Host "`n--- docker compose ps ---" -ForegroundColor Yellow
  docker compose ps
  Write-Host "`n--- docker compose logs ($ServiceName) ---" -ForegroundColor Yellow
  docker compose logs --tail 200 $ServiceName
  exit 1
}

# ------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker CLI not found. Start Docker Desktop and retry."
}

# Force compose project name = bpdi
$env:COMPOSE_PROJECT_NAME = "bpdi"

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

New-Item -ItemType Directory -Force $Root | Out-Null
$RootPosix = $Root -replace '\\','/'

$Data       = Join-Path $Root "data"
$Materials  = Join-Path $Root "materials"

$PgData     = Join-Path $Root "customer-pgdata"
$PgInitDir  = Join-Path $Root "customer-pg-init"
$PgInitSql  = Join-Path $PgInitDir "001_registered_customers.sql"

$MailData   = Join-Path $Root "smtp4dev-data"

$QdrantData = Join-Path $Root "qdrant-data"

New-Item -ItemType Directory -Force `
  $Data, $Materials, $PgData, $PgInitDir, $MailData, $QdrantData | Out-Null

# ------------------------------------------------------------
# n8n .env (SQLite only)
#   CHANGE: do not change password on reruns
# ------------------------------------------------------------

$EnvFile = Join-Path $Root ".env"

$User = $env:USERNAME
$ExistingN8nPass = Get-EnvValue -Path $EnvFile -Key "N8N_BASIC_AUTH_PASSWORD"
$Pass = if ($ExistingN8nPass) { $ExistingN8nPass } else { New-RandomSafeString 16 }

@(
  "N8N_LISTEN_ADDRESS=0.0.0.0"
  "N8N_PORT=5678"
  "N8N_PROTOCOL=http"
  "N8N_HOST=localhost"
  "WEBHOOK_URL=http://localhost:$Port"
  "N8N_EDITOR_BASE_URL=http://localhost:$Port"

  "N8N_BASIC_AUTH_ACTIVE=true"
  "N8N_BASIC_AUTH_USER=$User"
  "N8N_BASIC_AUTH_PASSWORD=$Pass"

  "GENERIC_TIMEZONE=Europe/Stockholm"
  "N8N_LOG_LEVEL=debug"

  # ---- IMPORTANT SECURITY / DEV SETTINGS ----
  "NODES_EXCLUDE=[]"                          # allow Execute Command
  "N8N_RESTRICT_FILE_ACCESS_TO=/materials"    # restrict FS access
  "N8N_FILESYSTEM_ALLOWED_PATHS=/materials"   # explicitly allow materials
) | Set-Content $EnvFile -Encoding UTF8

# ------------------------------------------------------------
# Customer PostgreSQL env
#   CHANGE: do not change password on reruns
# ------------------------------------------------------------

$CustomerDbName = "app"
$CustomerDbUser = "app"

$CustomerEnv = Join-Path $Root ".env.customerdb"
$ExistingCustomerDbPass = Get-EnvValue -Path $CustomerEnv -Key "POSTGRES_PASSWORD"
$CustomerDbPass = if ($ExistingCustomerDbPass) { $ExistingCustomerDbPass } else { New-RandomSafeString 24 }

@(
  "POSTGRES_DB=$CustomerDbName"
  "POSTGRES_USER=$CustomerDbUser"
  "POSTGRES_PASSWORD=$CustomerDbPass"
) | Set-Content $CustomerEnv -Encoding UTF8

# ------------------------------------------------------------
# PostgreSQL init SQL (REGISTERED CUSTOMERS)
#   (written without here-string terminators)
# ------------------------------------------------------------

@(
'CREATE TABLE IF NOT EXISTS registered_customers ('
'  id BIGSERIAL PRIMARY KEY,'
''
'  full_name TEXT,'
'  email TEXT,'
'  swedish_national_identity_number TEXT UNIQUE,'
'  nationality TEXT,'
'  country_of_residence TEXT,'
'  current_address TEXT,'
'  employment_status TEXT,'
'  main_source_of_income TEXT,'
'  purpose_of_account TEXT,'
'  expected_monthly_transaction_volume TEXT,'
'  transferring_money_to TEXT,'
'  earning_explanation TEXT'
');'
) | Set-Content $PgInitSql -Encoding UTF8


# ------------------------------------------------------------
# docker-compose.yml
#   (written without here-string terminators)
# ------------------------------------------------------------

@(
'name: bpdi'
''
'services:'
'  customer-postgres:'
'    image: postgres:16'
'    container_name: bpdi-customer-postgres'
'    env_file: .env.customerdb'
'    volumes:'
"      - ""${RootPosix}/customer-pgdata:/var/lib/postgresql/data"""
"      - ""${RootPosix}/customer-pg-init:/docker-entrypoint-initdb.d"""
'    ports:'
"      - ""${CustomerPgPort}:5432"""
'    restart: unless-stopped'
''
'  smtp4dev:'
'    image: rnwood/smtp4dev:latest'
'    container_name: bpdi-smtp4dev'
'    ports:'
"      - ""${Smtp4devWebPort}:80"""
"      - ""${Smtp4devSmtpPort}:25"""
"      - ""${Smtp4devImapPort}:143"""
'    volumes:'
"      - ""${RootPosix}/smtp4dev-data:/smtp4dev"""
'    restart: unless-stopped'
''
'  roundcube:'
'    image: roundcube/roundcubemail:latest'
'    container_name: bpdi-roundcube'
'    depends_on:'
'      - smtp4dev'
'    environment:'
'      ROUNDCUBEMAIL_DEFAULT_HOST: smtp4dev'
'      ROUNDCUBEMAIL_DEFAULT_PORT: 143'
'      ROUNDCUBEMAIL_SMTP_SERVER: smtp4dev'
'      ROUNDCUBEMAIL_SMTP_PORT: 25'
'    ports:'
"      - ""${RoundcubePort}:80"""
'    restart: unless-stopped'
''
'  qdrant:'
'    image: qdrant/qdrant:v1.16.3'
'    container_name: bpdi-qdrant'
'    ports:'
"      - ""${QdrantHttpPort}:6333"""
"      - ""${QdrantGrpcPort}:6334"""
'    volumes:'
"      - ""${RootPosix}/qdrant-data:/qdrant/storage"""
'    restart: unless-stopped'
''
'  n8n:'
'    image: n8nio/n8n:2.7.1'
'    container_name: bpdi-n8n'
'    env_file: .env'
'    depends_on:'
'      - customer-postgres'
'      - smtp4dev'
'      - qdrant'
'    ports:'
"      - ""${Port}:5678"""
'    volumes:'
"      - ""${RootPosix}/data:/home/node/.n8n"""
"      - ""${RootPosix}/materials:/materials"""
'    extra_hosts:'
'      - "host.docker.internal:host-gateway"'
'    restart: unless-stopped'
) | Set-Content (Join-Path $Root "docker-compose.yml") -Encoding UTF8

# ------------------------------------------------------------
# Start containers
#   CHANGE: if containers exist, do NOT recreate them.
#   FIX: opt-in reset for customer postgres only (no delete unless switch used)
# ------------------------------------------------------------

$containerNames = @(
  "bpdi-customer-postgres",
  "bpdi-smtp4dev",
  "bpdi-roundcube",
  "bpdi-qdrant",
  "bpdi-n8n"
)

$anyExists = $false
foreach ($n in $containerNames) {
  if (Container-Exists $n) { $anyExists = $true; break }
}

Push-Location $Root

if ($ResetCustomerPostgres) {
  Write-Host "ResetCustomerPostgres enabled: removing ONLY bpdi-customer-postgres container and deleting ONLY:" -ForegroundColor Yellow
  Write-Host "  $PgData" -ForegroundColor Yellow

  docker rm -f bpdi-customer-postgres 2>$null | Out-Null

  if (Test-Path $PgData) {
    Remove-Item -Recurse -Force $PgData
  }
  New-Item -ItemType Directory -Force $PgData | Out-Null

  docker compose up -d
} else {
  if ($anyExists) {
    docker compose up -d --no-recreate
  } else {
    docker compose up -d
  }
}

if ($LASTEXITCODE -ne 0) { throw "docker compose up failed (exit code $LASTEXITCODE)" }

Start-Sleep 3

Wait-Running -ContainerName "bpdi-customer-postgres" -ServiceName "customer-postgres"
Wait-Running -ContainerName "bpdi-smtp4dev"         -ServiceName "smtp4dev"
Wait-Running -ContainerName "bpdi-roundcube"        -ServiceName "roundcube"
Wait-Running -ContainerName "bpdi-qdrant"           -ServiceName "qdrant"
Wait-Running -ContainerName "bpdi-n8n"              -ServiceName "n8n"

Pop-Location

# ------------------------------------------------------------
# PRINT CONNECTION INFO (UNCHANGED from your original)
# ------------------------------------------------------------

Write-Host ""
Write-Host "===================== BPDI STACK READY =====================" -ForegroundColor Green
Write-Host ""

Write-Host "n8n:"
Write-Host "  UI:        http://localhost:$Port"
Write-Host "  Username:  $User"
Write-Host "  Password:  $Pass"
Write-Host ""

Write-Host "Customer PostgreSQL (USE IN n8n Postgres node):" -ForegroundColor Cyan
Write-Host "  Host:     customer-postgres"
Write-Host "  Port:     5432"
Write-Host "  Database: $CustomerDbName"
Write-Host "  User:     $CustomerDbUser"
Write-Host "  Password: $CustomerDbPass"
Write-Host "  SSL:      disabled"
Write-Host ""

Write-Host "smtp4dev (DEV MAIL SERVER):" -ForegroundColor Cyan
Write-Host "  Web UI:    http://localhost:$Smtp4devWebPort"
Write-Host "  SMTP:      smtp4dev:25 (from n8n)"
Write-Host "  IMAP:      smtp4dev:143"
Write-Host "  Host SMTP: localhost:$Smtp4devSmtpPort"
Write-Host "  Host IMAP: localhost:$Smtp4devImapPort"
Write-Host ""

Write-Host "Roundcube (MAIL CLIENT):" -ForegroundColor Cyan
Write-Host "  Web UI: http://localhost:$RoundcubePort"
Write-Host "  Login:  any user / any password (dev)"
Write-Host ""

Write-Host "Qdrant (VECTOR DB):" -ForegroundColor Cyan
Write-Host "  Container HTTP: qdrant:6333 (from n8n)"
Write-Host "  Container gRPC: qdrant:6334 (from n8n)"
Write-Host "  Host HTTP:      http://localhost:$QdrantHttpPort"
Write-Host "  Host gRPC:      localhost:$QdrantGrpcPort"
Write-Host ""

Write-Host "Connecting to Ollama:" -ForegroundColor Cyan
Write-Host "  URL: http://host.docker.internal:11434"
Write-Host ""

Write-Host "Docker Compose project/group: bpdi"
Write-Host "Please note that it may take few minutes so that the postgresql will be ready to use"
Write-Host "============================================================"
