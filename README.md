# Craft CMS Preview System

Write a ticket with a markdown spec. An AI agent picks it up, creates a branch, implements the changes, opens a PR, and spins up a live preview environment — ready for human feedback.

That's the goal. Right now, the preview infrastructure is working: open a PR and a full Craft CMS environment is deployed automatically.

> **Experimental.** ⚠️ Built with [Claude Code](https://claude.com/claude-code) via SSH on a bare Hetzner server. Learning reference, not production-ready. Do not run on servers with sensitive data. No liability, use at your own risk.

## Screenshots

**n8n workflow** — Webhook → IF (closed?) → Launch or Destroy → Post PR comment

![n8n workflow](screenshots/n8n.png)

**PR comment** — Preview URL posted automatically when the environment is ready

![GitHub PR comment](screenshots/github.png)

## Vision

```
                        ┌─────────────────────────────┐
                        │  TODAY                       │
                        │                              │
  PR opened on GitHub ──┤  1. n8n receives webhook     │
                        │  2. Clones branch            │
                        │  3. composer install         │
                        │  4. Creates DB + Craft CMS   │
                        │  5. Boots preview container  │
                        │  6. Posts URL as PR comment   │
                        │                              │
  PR closed ────────────┤  7. Destroys container + DB  │
                        └─────────────────────────────┘

                        ┌─────────────────────────────┐
                        │  FUTURE                      │
                        │                              │
  Ticket created ───────┤  1. AI agent reads spec      │
  (GitHub Issue /       │  2. Creates branch           │
   Linear / etc.)       │  3. Implements changes       │
                        │  4. Opens PR                 │
                        │  5. Preview auto-deploys     │
                        │  6. Human reviews + comments │
                        │  7. Agent iterates on        │
                        │     feedback if needed       │
                        └─────────────────────────────┘
```

Each preview gets its own subdomain: `reponame-pr-21.preview.SERVER_IP.sslip.io`

## Stack

- **Hetzner CAX31** — ARM64, Ubuntu 24.04
- **Traefik** — reverse proxy, routes subdomains to containers
- **MySQL 8.0** — shared instance, one database per preview
- **n8n** — webhook receiver + orchestration (runs scripts via SSH)
- **craftcms/nginx:8.2** — one container per preview branch
- **sslip.io** — wildcard DNS from IP, no domain needed

## Current Status

**Preview infrastructure works end-to-end.** Open a PR → preview deploys → URL posted as comment.

- Clone, composer install, database creation, Craft install, container boot
- Traefik routing with sslip.io wildcard DNS (plain HTTP)
- Auto-generated security key and admin credentials from `.env`
- Teardown on re-push (synchronize) and PR close

**TODO:**
- [ ] Switch trigger from PR to ticket/issue creation
- [ ] Auto-create branch + PR from ticket spec
- [ ] Integrate AI agent (Claude Code) to implement changes from the ticket spec
- [ ] Agent reads PR/issue comments as feedback, pushes follow-up commits
- [ ] Preview auto-rebuilds on each push

**Known issues:**
- Traefik may need a restart after first container launch if it returns 504
- `SERVER_IP` is hardcoded in `n8n-workflow-preview-deploy.json` — needs to be updated per deployment (n8n expressions don't support nested `{{ }}`, so env vars can't be used here)
- n8n drops IF-node connections on JSON import — must be reconnected manually after every import

## Getting Started

### Prerequisites
- A **Hetzner Cloud** account (CAX31 ARM64 recommended, ~€7/mo)
- A **GitHub** fine-grained personal access token (Issues + Pull requests: read & write)
- [Claude Code](https://claude.com/claude-code) installed locally

### Setup (5 minutes of manual work, Claude Code does the rest)

1. **Create a Hetzner server** — CAX31, Ubuntu 24.04, add your SSH key during creation

2. **Clone this repo and configure**
   ```bash
   git clone https://github.com/mandrasch/n8n-craftcms.git
   cd n8n-craftcms
   cp .env.example .env
   # Edit .env — fill in your server IP and choose a MySQL password (no $ in password!)
   ```

3. **Copy your SSH key to the server**
   ```bash
   ssh-copy-id root@YOUR_SERVER_IP
   ```

4. **Open the folder in Claude Code and paste this prompt:**

   > See CLAUDE.md — SSH into the server and set up the preview system. My .env is configured. After server setup, guide me through n8n workflow import and GitHub webhook setup.

   Claude Code will SSH into your server and run through all setup phases automatically (Docker, Traefik, MySQL, n8n, scripts).

5. **Manual steps after server setup** (Claude Code will guide you):
   - Open n8n at `http://n8n.preview.YOUR_IP.sslip.io/`, create an account
   - Import `n8n-workflow-preview-deploy.json` — manually connect the IF node outputs (n8n import bug, see CLAUDE.md)
   - Add a **GitHub API** credential with your token
   - Add a GitHub webhook to your repo pointing to `http://n8n.preview.YOUR_IP.sslip.io/webhook/preview-deploy`
   - Activate the workflow

6. **Test it** — open a PR on your Craft CMS repo, a preview URL should appear as a PR comment
