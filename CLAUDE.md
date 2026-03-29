# CLAUDE.md — Craft CMS Feature Branch Preview System Setup

## Mission

Set up a fully automated feature branch preview system on this Hetzner server.
The system allows team members to open a PR → GitHub webhook fires → n8n catches it → clones the branch → boots a Docker preview → posts the preview URL back as a PR comment.

All configuration values are sourced from `.env` (see `.env.example`).

## Rules

- **Always keep docs in sync.** After any task or bugfix, update the affected files in the repo (`scripts/`, `infra/`, `template/`, `n8n-workflow-preview-deploy.json`) AND this `CLAUDE.md` and `README.md` to reflect the changes. Never leave the repo out of date with what's deployed on the server.
- **Deploy changes to the server** after updating repo files (scripts, templates, configs).
- **Document gotchas** in the Important Notes section when you hit and solve an issue.

## Current State

Server is set up and running (Ubuntu 24.04, Hetzner CAX31, ARM64).
Traefik, MySQL, n8n are running. Scripts are deployed. n8n workflow is imported and wired to GitHub webhooks. The PR → launch → comment flow is working end-to-end (composer install, Craft install, container boot). GitHub token permissions and n8n IF-node wiring required manual steps after import.

**Completed phases:** 1–8, 10, 11, 12
**Status:** PR → preview flow works end-to-end. Preview containers boot, Craft installs, site is accessible via Traefik.
**Remaining:** Confirm PR close → destroy flow, test with multiple concurrent previews

## Target Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Hetzner CAX31 (Ubuntu 24.04, ARM64)                    │
│                                                         │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────────┐ │
│  │ Traefik  │  │   n8n    │  │  Shared MySQL (1x)     │ │
│  │ :80      │  │  :5678   │  │  one DB per branch     │ │
│  └────┬─────┘  └────┬─────┘  └────────────┬───────────┘ │
│       │              │                     │             │
│       │    ┌─────────┴──────────┐          │             │
│       │    │  launch.sh         │          │             │
│       │    │  destroy.sh        │          │             │
│       │    │  cleanup.sh        │          │             │
│       │    └─────────┬──────────┘          │             │
│       │              │                     │             │
│  ┌────┴──────────────┴─────────────────────┴──────────┐ │
│  │           Preview Containers (per branch)           │ │
│  │  ┌─────────────┐ ┌─────────────┐ ┌──────────────┐  │ │
│  │  │craft-feat-a │ │craft-feat-b │ │craft-feat-c  │  │ │
│  │  │ PHP+nginx   │ │ PHP+nginx   │ │ PHP+nginx    │  │ │
│  │  │ port 8080   │ │ port 8080   │ │ port 8080    │  │ │
│  │  └─────────────┘ └─────────────┘ └──────────────┘  │ │
│  └────────────────────────────────────────────────────┘ │
│                                                         │
│  sslip.io → *.preview.SERVER_IP.sslip.io (no domain needed) │
└─────────────────────────────────────────────────────────┘
```

## PR-Triggered Flow

1. Developer opens a PR on GitHub
2. GitHub fires `pull_request` webhook (opened/synchronize/closed)
3. n8n receives it via Webhook node
4. IF action = `closed` → run `destroy.sh` → comment "Preview destroyed"
5. IF action = `opened`/`synchronize` → run `launch.sh` → comment preview URL
6. Preview URL is posted back as a PR comment

The PR description can serve as a task spec (for future Claude Code agent integration).

## Future: Ticket-Driven AI Agent Flow

The current system triggers on PR creation. The end goal is a ticket-driven flow:

1. Someone creates a ticket (GitHub Issue, Linear, etc.) with a markdown spec
2. n8n picks up the ticket via webhook
3. n8n triggers a Claude Code agent with the spec
4. Agent creates a branch, implements changes, opens a PR
5. Preview environment auto-deploys (existing infrastructure)
6. Human reviews the preview, leaves feedback as PR/issue comments
7. Agent reads feedback, pushes follow-up commits
8. Preview auto-rebuilds on each push

**TODO for this phase:**
- Switch trigger source from PR to ticket/issue creation
- Add n8n node to auto-create branch + PR from ticket
- Integrate Claude Code agent (via CLI or API) to implement the spec
- Add feedback loop: agent reads PR comments, iterates

## Step-by-Step Setup

Work through these phases in order. After each phase, verify it works before moving on.
All values come from `.env` — source it at the start of each phase/script.

---

### Phase 1: Server Hardening + Docker

1. Update system: `apt update && apt upgrade -y`
2. Create `deploy` user with sudo, copy SSH keys via `ssh-copy-id`
3. Disable password auth in sshd_config
4. Set up ufw (allow SSH, 80, 443)
5. Install fail2ban
6. Install Docker + Docker Compose plugin
7. Add deploy user to docker group

**Verify:** `docker --version` and `docker compose version` both work as deploy user.

---

### Phase 2: Directory Structure

**On the server** (`~/preview-system/`):
```
~/preview-system/
├── traefik/docker-compose.yml    ← from infra/traefik/
├── mysql/docker-compose.yml      ← from infra/mysql/
├── n8n/docker-compose.yml        ← from infra/n8n/
├── .env                          ← sourced by all scripts
├── template/docker-compose.yml   ← from template/
├── previews/                     ← one subfolder per active branch
├── scripts/
│   ├── launch.sh                 ← from scripts/
│   ├── destroy.sh
│   └── cleanup.sh
└── logs/
```

**In this repo:**
```
├── infra/
│   ├── traefik/docker-compose.yml
│   ├── mysql/docker-compose.yml
│   └── n8n/docker-compose.yml
├── template/docker-compose.yml
├── scripts/
│   ├── launch.sh
│   ├── destroy.sh
│   └── cleanup.sh
├── n8n-workflow-preview-deploy.json
├── .env.example
├── CLAUDE.md
└── README.md
```

---

### Phase 3: Traefik

Copy `infra/traefik/docker-compose.yml` to `~/preview-system/traefik/` on the server.

```bash
scp infra/traefik/docker-compose.yml deploy@SERVER_IP:~/preview-system/traefik/
ssh deploy@SERVER_IP "cd ~/preview-system/traefik && docker compose up -d"
```

**Note:** Traefik exposes the API dashboard on port 8080 (`--api.insecure=true`) for debugging. Debug logging is enabled. Disable both in production.

**Verify:** `docker ps` shows traefik running, `curl -I http://localhost` returns a response.

---

### Phase 4: Shared MySQL

Copy `infra/mysql/docker-compose.yml` to `~/preview-system/mysql/` on the server.

```bash
scp infra/mysql/docker-compose.yml deploy@SERVER_IP:~/preview-system/mysql/
ssh deploy@SERVER_IP "cd ~/preview-system/mysql && docker compose up -d"
```

**Note:** The `mysql/` directory needs its own `.env` file with the same `MYSQL_ROOT_PASSWORD`. Do NOT use `$` in the password — it causes issues with both bash variable expansion and Docker Compose interpolation.

**Verify:** `docker exec shared-mysql mysql -uroot -p"PASSWORD" -e "SELECT 1;"` returns 1.

---

### Phase 5: n8n

Copy `infra/n8n/docker-compose.yml` to `~/preview-system/n8n/` on the server.

```bash
scp infra/n8n/docker-compose.yml deploy@SERVER_IP:~/preview-system/n8n/
ssh deploy@SERVER_IP "cd ~/preview-system/n8n && docker compose up -d"
```

**Note:** The workflow uses the SSH node (not `executeCommand`, which is disabled by default in n8n 2.x). `NODES_EXCLUDE=[]` ensures all built-in nodes are available.

**Verify:** n8n is reachable at `http://n8n.preview.SERVER_IP.sslip.io`, or at minimum `docker logs n8n` shows successful startup.

---

### Phase 6: Craft CMS Preview Template

Copy `template/docker-compose.yml` to `~/preview-system/template/` on the server.

```bash
scp template/docker-compose.yml deploy@SERVER_IP:~/preview-system/template/
```

The template uses `__PLACEHOLDER__` variables that `launch.sh` replaces with actual values via `sed`. See `template/docker-compose.yml` for the full list.

**Note:** The `CRAFT_DB_PASSWORD` must match the MySQL root password from Phase 4.
The `CRAFT_SECURITY_KEY` is auto-generated by `launch.sh` if left empty in `.env`.

---

### Phase 7: Baseline Database Dump

**SKIPPED FOR NOW.** The launch script will create an empty database and let Craft run `install` or `migrate` on first boot. Database dump import can be added later by placing a `baseline.sql.gz` file in `~/preview-system/template/`.

---

### Phase 8: Scripts

The scripts are in the `scripts/` directory of this repo. Copy them to the server:

```bash
scp scripts/*.sh deploy@SERVER_IP:~/preview-system/scripts/
ssh deploy@SERVER_IP "chmod +x ~/preview-system/scripts/*.sh"
```

Also copy the preview container template:

```bash
scp template/docker-compose.yml deploy@SERVER_IP:~/preview-system/template/
```

**Scripts overview:**
- **`scripts/launch.sh BRANCH REPO_URL REPO_NAME PR_NUMBER`** — clones branch, runs `composer install` + `npm run build` (via Docker), creates DB, boots Craft CMS container, runs `craft install` or migrations. Preview ID: `reponame-pr-NUMBER`
- **`scripts/destroy.sh REPO_NAME PR_NUMBER`** — stops container, removes files, drops database
- **`scripts/cleanup.sh`** — auto-destroys previews older than 48 hours

**Key details:**
- Composer runs via `composer:latest` image with `--ignore-platform-reqs` (bcmath etc. available at runtime in craftcms container)
- npm runs via `node:lts-alpine` image (only if `package.json` exists)
- Both use `-u "$(id -u):$(id -g)"` to avoid root-owned files
- `CRAFT_SECURITY_KEY` is auto-generated if empty in `.env`
- Fresh installs use `CRAFT_ADMIN_EMAIL` and `CRAFT_ADMIN_PASSWORD` from `.env`
- Teardown uses `sudo rm -rf` to handle root-owned files from previous runs

**Verify:** Run a test launch with a real branch from the repo:
```bash
~/preview-system/scripts/launch.sh "main" "https://github.com/org/repo.git"
```
Check that the preview URL loads, admin panel works.
Then destroy it: `~/preview-system/scripts/destroy.sh "main"`

---

### Phase 9: Cloudflare Tunnel

**SKIPPED.** Using sslip.io for DNS — no tunnel or domain needed. Previews are plain HTTP via Traefik on port 80. Each preview gets a subdomain like `reponame-pr-21.preview.SERVER_IP.sslip.io`.

---

### Phase 10: Git Access

**Public repos** work out of the box — `launch.sh` clones via HTTPS. Use HTTPS-style `GIT_REPO_URL` in `.env` (e.g. `https://github.com/org/repo.git`). No deploy key needed.

**Private repos** require a deploy key on the server:

```bash
# Generate deploy key
ssh-keygen -t ed25519 -C "preview-system" -f ~/.ssh/preview_deploy_key -N ""

# Show public key — add this as a deploy key in your Git host
cat ~/.ssh/preview_deploy_key.pub

# Configure SSH to use this key for the git host
cat >> ~/.ssh/config << 'EOF'
Host github.com
  IdentityFile ~/.ssh/preview_deploy_key
  IdentitiesOnly yes
EOF
# Adjust Host if using Gitea, GitLab, Bitbucket, etc.
```

Then use SSH-style `GIT_REPO_URL` in `.env` (e.g. `git@github.com:org/repo.git`).

**Verify (private only):** `ssh -T git@github.com` (or equivalent) succeeds.

---

### Phase 11: End-to-End Test

Run through the full flow manually:

1. `~/preview-system/scripts/launch.sh "main" "$GIT_REPO_URL" "my-repo" "99"`
2. Wait for output showing the preview URL
3. Open `http://my-repo-pr-99.preview.SERVER_IP.sslip.io` — should show the site
4. Open `http://my-repo-pr-99.preview.SERVER_IP.sslip.io/admin` — should show Craft admin login
5. `~/preview-system/scripts/destroy.sh "my-repo" "99"` — should clean up
6. Verify database is gone: `docker exec shared-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES LIKE 'craft_%';"`

If all passes, the system is ready for n8n webhook integration.

---

### Phase 12: n8n Workflow + GitHub Webhook

#### n8n SSH Credential

The n8n workflow uses the **SSH node** (`n8n-nodes-base.ssh`) to execute `launch.sh` and `destroy.sh` on the host. The `executeCommand` node is disabled by default in n8n 2.x, so the SSH node is used instead.

Setup:
1. Generate an SSH key inside the n8n container:
   ```bash
   docker exec n8n sh -c 'mkdir -p /home/node/.ssh && ssh-keygen -t ed25519 -f /home/node/.ssh/id_ed25519 -N "" -q'
   ```
2. Add the public key to the deploy user's authorized_keys:
   ```bash
   docker exec n8n cat /home/node/.ssh/id_ed25519.pub >> /home/deploy/.ssh/authorized_keys
   ```
3. Test SSH from n8n container to host:
   ```bash
   docker exec n8n ssh -o StrictHostKeyChecking=no deploy@172.17.0.1 "echo ok"
   ```
4. In n8n UI → Settings → Credentials → Add → **SSH**:
   - **Host:** `172.17.0.1` (Docker bridge gateway = host machine)
   - **Port:** `22`
   - **User:** `deploy`
   - **Authentication:** Private Key
   - **Private Key:** paste the output of `docker exec n8n cat /home/node/.ssh/id_ed25519`

#### n8n Workflow

Import `n8n-workflow-preview-deploy.json` from this repo into n8n.

**Known issue:** n8n 2.x has a bug where IF node connections are dropped during JSON import. After importing, manually connect:
1. **Is Closed** `true` output → **Destroy Preview** → **Comment Destroyed**
2. **Is Closed** `false` output → **Launch Preview** → **Comment Preview URL**

Also click each node with a `?` icon or warning triangle and select the appropriate credential (SSH credential for command nodes, GitHub API credential for HTTP Request nodes).

The workflow consists of 6 nodes:
- **Webhook** — receives POST from GitHub at `/webhook/preview-deploy`
- **Is Closed** — IF node: checks if `action` = `closed`
- **Destroy Preview** — SSH node: runs `destroy.sh` (true branch)
- **Launch Preview** — SSH node: runs `launch.sh` (false branch)
- **Comment Destroyed** — HTTP Request: posts "preview destroyed" comment on PR
- **Comment Preview URL** — HTTP Request: posts preview URL comment on PR

#### GitHub API Credential

In n8n → Settings → Credentials → Add → **GitHub API** → paste a fine-grained personal access token.

Required token permissions (scoped to selected repositories only):
- **Pull requests:** Read and write
- **Issues:** Read and write (PR comments use the Issues API)

This is used by the HTTP Request nodes to post PR comments.

#### GitHub Webhook

In your GitHub repo → Settings → Webhooks → Add webhook:
- **Payload URL:** `http://n8n.preview.SERVER_IP.sslip.io/webhook/preview-deploy`
- **Content type:** `application/json`
- **Events:** select "Pull requests" only
- **Active:** yes

#### Activate

In n8n, toggle the workflow to **Active**.

**Verify:** Open a PR on GitHub → n8n should launch a preview and post the URL as a comment. Close the PR → n8n should destroy the preview and comment.

---

## Configuration

All values are read from `~/preview-system/.env` (see `.env.example` in this repo).

| Value | Variable | Example |
|-------|----------|---------|
| Server IP | `SERVER_IP` | `123.45.67.89` |
| MySQL root password | `MYSQL_ROOT_PASSWORD` | (strong password, no `$`) |
| Craft security key | `CRAFT_SECURITY_KEY` | (optional — auto-generated if empty) |
| Craft admin email | `CRAFT_ADMIN_EMAIL` | `admin@example.com` |
| Craft admin password | `CRAFT_ADMIN_PASSWORD` | `change-me` |
| Git repo URL | `GIT_REPO_URL` | `https://github.com/org/repo.git` |

## Important Notes

- **SSH key auth only** — no password auth. Use `ssh-copy-id` to set up access before running setup.
- **ARM64 server** (Hetzner CAX31). Docker images must support `linux/arm64`. The `craftcms/nginx:8.2`, `mysql:8.0`, `traefik:latest`, and `n8nio/n8n` images all support ARM64. Note: `craftcms/nginx:8.3` does not exist — use `8.2`.
- **Traefik** must use `latest` (not v3.1/v3.4) — older versions have a Docker API client that's incompatible with Docker Engine 29.x. If Traefik returns 504 for new containers, restart it (`docker compose up -d --force-recreate` in the traefik directory) — it can get stale routing state.
- **MySQL password:** do NOT use `$` in the password. It causes issues with bash variable expansion and Docker Compose interpolation. Stick to alphanumeric characters and simple symbols (`: @ ! % ^ & * _`).
- **No domain needed** — uses sslip.io for wildcard DNS. Any IP maps automatically (e.g. `feat.preview.1.2.3.4.sslip.io` → `1.2.3.4`). No SSL (plain HTTP) since sslip.io rate-limits Let's Encrypt.
- **n8n uses SSH node** (not `executeCommand`) — the `executeCommand` node is disabled by default in n8n 2.x for security. The SSH node connects to the host via `172.17.0.1` (Docker bridge gateway).
- **Composer install** uses the `composer:latest` Docker image with `--ignore-platform-reqs` (bcmath etc. are available at runtime in the craftcms container, not needed at install time).
- **Craft install** runs automatically on fresh databases using `CRAFT_ADMIN_EMAIL` and `CRAFT_ADMIN_PASSWORD` from `.env`. If a `baseline.sql.gz` dump exists, it imports that and runs migrations instead.
- All scripts source `~/preview-system/.env` for credentials — nothing is hardcoded.
- Each preview container uses ~150MB RAM (shared MySQL). The server can handle ~8–10 concurrent previews comfortably.
- Previews auto-cleanup after 48 hours via cleanup.sh. Set up a cron job or n8n cron node to run it.
- The n8n container has Docker socket access — this is a security tradeoff for convenience. Fine for a dev preview system, not for production.
