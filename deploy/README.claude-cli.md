# Open Design — Server mit gebundeltem Claude CLI

Variante des Standard-Deployments mit **Claude CLI im Image** und **Subscription-Login** (kein API-Key). Pendant zum Upstream `deploy/Dockerfile`, das die CLIs bewusst nicht mitliefert.

Zwei Compose-Profile:

- **Local** (`docker-compose.claude-cli.yml`) — Image wird lokal gebaut. Fuer Build-Maschinen und Single-Server-Setups.
- **Server** (`docker-compose.claude-cli.server.yml`) — Image kommt aus Registry (`ghcr.io/<user>/open-design-claude:latest`), Watchtower ist mit dabei und macht Auto-Update alle 6h.

Switch zwischen beiden:

```bash
# Default: lokaler Build
./od-claude.sh

# Server-Mode (Pull + Watchtower):
OD_COMPOSE_FILE=$(pwd)/../docker-compose.claude-cli.server.yml ./od-claude.sh
```

## Was anders ist als das Upstream-Setup

| | Upstream | Diese Variante |
|---|---|---|
| Image | `Dockerfile` | `Dockerfile.claude-cli` |
| Compose | `docker-compose.yml` | `docker-compose.claude-cli.yml` |
| Env | `.env.example` | `.env.claude-cli.example` |
| Container-Name | `open-design` | `open-design-claude` |
| Volumes | `open_design_data` | `open_design_data` + `claude_home` |
| Claude CLI im Image | ❌ | ✓ (`@anthropic-ai/claude-code`) |
| RAM-Default | 384m | 2g |
| `read_only` FS | ✓ | ✗ (Token-Rotation braucht Schreibrechte) |

Beide Setups laufen konfliktfrei parallel – andere Image-Tags, Compose-Projektnamen und Volume-Namen.

## Voraussetzungen

- Docker + Docker Compose v2
- Domain mit A-Record auf den Server (für TLS)
- Aktiver Claude Pro/Max Account
- Reverse Proxy mit Auth davor (siehe `nginx.claude-cli.example.conf`)

## Setup in 3 Schritten

```bash
cd deploy/scripts
./od-claude.sh 12 1 2 22
#              │  │ │ └── Test-Prompt
#              │  │ └──── Login (Subscription, Device-Flow)
#              │  └────── Up (Container starten)
#              └───────── Build (Image bauen)
```

Alternativ interaktiv mit Multi-Select:

```bash
./od-claude.sh
# Im TUI: 12 markieren, 1 markieren, 2 markieren, 22 markieren → Enter
```

Beim Login öffnet sich `claude setup-token` im Container und gibt eine URL aus. URL **auf deinem lokalen Rechner** im Browser öffnen, mit Pro/Max-Account einloggen, Code zurück ins Terminal pasten. Tokens landen im Volume `claude_home`, überleben Restarts/Rebuilds.

## Konfiguration

`.env.claude-cli` wird beim ersten Start aus `.env.claude-cli.example` kopiert:

```ini
OPEN_DESIGN_IMAGE=open-design:claude-cli
CLAUDE_CLI_VERSION=latest               # oder konkret: 1.0.45
OPEN_DESIGN_PORT=7456
OPEN_DESIGN_BIND=127.0.0.1              # NICHT 0.0.0.0 ohne Reverse Proxy
OPEN_DESIGN_ALLOWED_ORIGINS=https://design.example.com
OPEN_DESIGN_MEM_LIMIT=2g
NODE_OPTIONS=--max-old-space-size=1024
```

**Wichtig**: `ANTHROPIC_API_KEY` **nicht** setzen. Sonst nutzt das CLI den API-Key statt der Subscription.

## Reverse Proxy + TLS

Daemon hat **keine eigene Authentifizierung**. Vor Internet-Exposition zwingend Reverse Proxy mit Auth:

```bash
sudo apt install nginx apache2-utils certbot python3-certbot-nginx
sudo htpasswd -c /etc/nginx/.od-htpasswd <username>
sudo cp deploy/nginx.claude-cli.example.conf /etc/nginx/sites-available/open-design
sudo ln -s /etc/nginx/sites-available/open-design /etc/nginx/sites-enabled/
sudo certbot --nginx -d design.example.com
sudo nginx -t && sudo systemctl reload nginx
```

Siehe `deploy/nginx.claude-cli.example.conf` für Details inkl. SSE-Buffering und Caddy-Alternative.

## Helper-Skript Übersicht

`deploy/scripts/od-claude.sh` (rm-picvault-Stil, TUI + Batch).

```
Docker
   1  Container starten
  11  Container stoppen
  12  Image bauen
  13  Container neu starten
  14  Status / Health
  15  Logs (follow)
  16  Shell im Container
  17  Image aus Registry pullen

Claude CLI
   2  Login (Subscription / OAuth)
  21  Login-Status pruefen
  22  Test-Prompt absetzen
  23  Logout (credentials.json loeschen)
  24  Claude CLI im Container updaten

Konfiguration
   3  .env bearbeiten
  31  Compose-Konfig anzeigen
  39  Volumes + Container loeschen (DESTRUKTIV)
```

Batch-Aufruf: `./od-claude.sh 1 22` führt 1 und dann 22 aus. Im TUI mit Space mehrere markieren, Reihenfolge bleibt erhalten.

## Persistenz

- `open_design_data` → `/app/.od` (SQLite, Projekte, Artefakte, media-config)
- `claude_home` → `/home/open-design/.claude` (OAuth-Credentials, CLI-State)

Beide überleben `down`/`up`/`build`. **Nur** `od-claude.sh 39` (Down + `-v`) entfernt sie. Vor Rebuilds also nicht löschen – Login bleibt erhalten.

## Updates

### Server-Mode mit Auto-Update (empfohlen)

Wenn du den `claude-cli.server.yml` Compose nutzt, ist **Watchtower** schon mit dabei und prüft alle 6h ob ein neueres Image in der Registry liegt. Wenn ja: Pull + Restart automatisch. **Du machst gar nichts.**

Der Build passiert via GitHub Action im Fork:

- Nightly Job (04:30 UTC) merged Upstream `nexu-io/open-design`
- Bei sauberem Merge → Multi-Arch Build → Push nach GHCR
- Bei Konflikt → Issue im Fork, manueller Eingriff

Workflow-Template: `deploy/github-workflow.claude-cli-server.yml`.

### Local-Mode (manueller Rebuild)

```bash
git pull
./od-claude.sh 12 13       # rebuild + restart
```

Claude CLI Version pinnen: `CLAUDE_CLI_VERSION=1.0.45` in `.env.claude-cli`.

## Fork-Setup (einmalig, fuer Auto-Update)

```bash
# 1. Fork via gh CLI
gh repo fork nexu-io/open-design --clone=false

# 2. Lokal Remote umbiegen
cd ~/projects/tools/open-design
git remote rename origin upstream
git remote add origin git@github.com:<dein-user>/open-design.git
git checkout -b claude-cli-deploy

# 3. Custom-Dateien committen
git add deploy/Dockerfile.claude-cli \
        deploy/docker-compose.claude-cli*.yml \
        deploy/.env.claude-cli.example \
        deploy/scripts/od-claude.sh \
        deploy/scripts/lib/ \
        deploy/nginx.claude-cli.example.conf \
        deploy/README.claude-cli.md \
        deploy/github-workflow.claude-cli-server.yml \
        .gitignore
git commit -m "deploy: claude-cli server variant"

# 4. Workflow aktivieren (kollidiert nicht mit Upstream)
mkdir -p .github/workflows
cp deploy/github-workflow.claude-cli-server.yml .github/workflows/claude-cli-server.yml
git add .github/workflows/claude-cli-server.yml
git commit -m "ci: nightly claude-cli image build"

# 5. Push
git push -u origin claude-cli-deploy

# 6. Auf GitHub: erstes Image manuell triggern
gh workflow run claude-cli-server.yml --ref claude-cli-deploy
```

Danach ist `ghcr.io/<dein-user>/open-design-claude:latest` verfuegbar. Image ist standardmaessig privat – entweder Visibility auf public schalten (im GitHub Package-Settings) oder GHCR-PAT in `~/.docker/config.json` auf dem Server hinterlegen, damit Watchtower pullen darf.

## Server-Deploy (Server-Mode mit Auto-Update)

Auf dem Server brauchst du **nur diese Dateien**, nicht den ganzen Source-Tree:

```
/opt/open-design/
├── deploy/
│   ├── docker-compose.claude-cli.server.yml
│   ├── .env.claude-cli
│   ├── nginx.claude-cli.example.conf
│   └── scripts/
│       ├── od-claude.sh
│       └── lib/
│           ├── colors.sh
│           └── docker.sh
```

Bootstrap auf dem Server:

```bash
# Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker

# Sparse Checkout: nur deploy/ aus deinem Fork
sudo mkdir -p /opt && sudo chown $USER /opt
cd /opt
git clone --depth 1 --filter=blob:none --sparse \
  -b claude-cli-deploy git@github.com:<dein-user>/open-design.git
cd open-design
git sparse-checkout set deploy

# Env anlegen
cp deploy/.env.claude-cli.example deploy/.env.claude-cli
# In .env.claude-cli:
#   OPEN_DESIGN_IMAGE=ghcr.io/<dein-user>/open-design-claude:latest
#   OPEN_DESIGN_ALLOWED_ORIGINS=https://design.example.com
nano deploy/.env.claude-cli

# GHCR Login (nur falls Image privat)
echo $GHCR_PAT | docker login ghcr.io -u <dein-user> --password-stdin

# Start im Server-Mode
cd deploy/scripts
export OD_COMPOSE_FILE=$(pwd)/../docker-compose.claude-cli.server.yml
./od-claude.sh 17 1 2 22   # Pull, Up, Login, Test
```

Ab jetzt **autopilot**:
- Watchtower zieht alle 6h neue Image-Versionen
- GitHub Action baut taeglich aus Upstream
- Server-Wartung: 0

## Troubleshooting

**"creds: NICHT gefunden"** → Login mit Option 2 nachholen.

**Test-Prompt schlägt fehl mit "API Error"** → `ANTHROPIC_API_KEY` ist gesetzt und überschreibt die Subscription. In `.env.claude-cli` entfernen, Container neu starten.

**Container startet, dann unhealthy** → `./od-claude.sh 15` und nach Port-Konflikten, Permission-Denials auf `.od` oder `.claude` schauen. Volumes ggf. neu anlegen (Option 39, ACHTUNG: löscht Login + Projekte).

**OAuth-Token läuft ab im Hintergrund** → Volume muss schreibbar bleiben. `read_only` ist in der Compose-Variante absichtlich `false`.

## Sicherheits-Checkliste

- [ ] Port nur an 127.0.0.1 gebunden (`OPEN_DESIGN_BIND=127.0.0.1`)
- [ ] Reverse Proxy mit TLS davor
- [ ] Basic-Auth oder OAuth-Proxy (Authelia, oauth2-proxy, Cloudflare Access)
- [ ] `OPEN_DESIGN_ALLOWED_ORIGINS` exakt auf die Domain gesetzt
- [ ] `.env.claude-cli` nicht committed (in `.gitignore`)
- [ ] Firewall: nur 80/443 öffentlich, 7456 nicht erreichbar
- [ ] Backups vom `claude_home` und `open_design_data` Volume
