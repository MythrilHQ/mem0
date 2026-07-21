# EC2 Docker host bootstrap cookbook

This runbook prepares a new Ubuntu EC2 instance to host Dockerized products behind Traefik v3 and deploy them through a self-hosted GitHub Actions runner.

**Scope:** EC2 prerequisites, host hardening, Docker Engine and Compose, Dockerized Traefik v3, DNS prerequisites, runner registration, and host maintenance.

**Out of scope:** cloning, configuring, deploying, initializing, testing, backing up, or administering Mem0 or any other product. Application workflows checked out by the runner own those tasks.

## Result

```text
Internet
   |
   | TCP 80/443
   v
Traefik v3 container
   |
   +-- Docker network: proxy
          |
          +-- future product containers deployed by the runner

GitHub Actions
   |
   v
self-hosted runner -> Docker Engine -> future product stacks
```

The only public services on the host are SSH (restricted), HTTP, and HTTPS. Traefik creates the shared `proxy` network; future Compose projects join it as an external network.

## Before connecting

Complete these items in the AWS console.

### Stable address

1. Allocate an Elastic IP in the instance's region.
2. Associate it with the instance.
3. Use that Elastic IP for SSH and DNS.

Do not use the auto-assigned public address in permanent DNS. It can change after a stop/start cycle.

### Security group

Allow only:

| Protocol | Port | Source |
|---|---:|---|
| TCP | 22 | Your office/VPN public IP as `/32` |
| TCP | 80 | `0.0.0.0/0` |
| TCP | 443 | `0.0.0.0/0` |

Do not expose Docker, Traefik's dashboard, databases, or application ports directly.

### Instance settings

- Keep IMDSv2 required.
- Enable termination protection.
- Use at least a 30 GiB gp3 root volume.
- Configure EBS snapshots or AWS Backup.
- Add alarms for `StatusCheckFailed` and low `CPUCreditBalance`.

A `t2.medium` is adequate for initial setup but may struggle with concurrent image builds. Prefer at least 2 vCPU and 8 GiB RAM for sustained builds or multiple products.

## 1. Connect and update Ubuntu

From your workstation:

```bash
chmod 600 ~/.ssh/server-key.pem
ssh -i ~/.ssh/server-key.pem ubuntu@ELASTIC_IP
```

On the server:

```bash
cat /etc/os-release
uname -m
df -h /
free -h

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
sudo apt-get install -y \
  ca-certificates \
  curl \
  dnsutils \
  fail2ban \
  git \
  jq \
  openssl \
  rsync \
  unattended-upgrades \
  ufw
sudo timedatectl set-timezone UTC
sudo hostnamectl set-hostname docker-host-01
```

If a reboot is required, reboot and reconnect:

```bash
if [ -f /var/run/reboot-required ]; then
  sudo reboot
fi
```

## 2. Add swap and basic hardening

A 4 GiB swap file reduces out-of-memory failures during image builds on small instances:

```bash
if ! sudo swapon --show=NAME --noheadings | grep -qx '/swapfile'; then
  sudo fallocate -l 4G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || \
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo swapon --show
```

Enable automatic security updates:

```bash
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
sudo systemctl enable --now unattended-upgrades
```

Configure the host firewall:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
sudo ufw status verbose
```

Disable root and password-based SSH. Keep the current session open until a second SSH session succeeds:

```bash
sudo tee /etc/ssh/sshd_config.d/99-host-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowUsers ubuntu
EOF
sudo sshd -t
sudo systemctl reload ssh

sudo tee /etc/fail2ban/jail.d/sshd.local >/dev/null <<'EOF'
[sshd]
enabled = true
EOF
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

Open a second terminal and verify key-based SSH before closing the first session.

## 3. Install Docker Engine and Compose

Use Docker's official Ubuntu repository:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

. /etc/os-release
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
sudo apt-get install -y \
  containerd.io \
  docker-buildx-plugin \
  docker-ce \
  docker-ce-cli \
  docker-compose-plugin
```

If Docker does not publish packages for the installed Ubuntu release, use a Docker-supported Ubuntu LTS image instead of mixing unofficial packages.

Bound container logs and enable live restore:

```bash
sudo install -m 0755 -d /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "live-restore": true,
  "log-driver": "local",
  "log-opts": {
    "max-file": "5",
    "max-size": "20m"
  }
}
EOF
sudo systemctl restart docker
sudo systemctl enable docker
sudo usermod -aG docker ubuntu
```

Reconnect so Docker group membership applies, then verify:

```bash
docker version
docker compose version
docker run --rm hello-world
```

The Docker group is effectively root access. Add only trusted administrators and the deployment runner.

## 4. Install Traefik v3 as a Docker container

Traefik is a standalone Compose project in `server/traefik/`. Copy only that directory to the host; do not clone or install the application repository.

From your workstation, at the repository root:

```bash
scp -i ~/.ssh/server-key.pem -r \
  server/traefik \
  ubuntu@ELASTIC_IP:/tmp/traefik
```

On the server:

```bash
sudo install -d -m 0750 /opt/traefik
sudo rsync -a /tmp/traefik/ /opt/traefik/
sudo chown -R root:root /opt/traefik
sudo cp /opt/traefik/.env.example /opt/traefik/.env
sudo chmod 600 /opt/traefik/.env
sudoedit /opt/traefik/.env
```

Set:

```dotenv
TRAEFIK_IMAGE_TAG=v3.X.Y
ACME_EMAIL=ops@example.com
TRAEFIK_LOG_LEVEL=INFO
```

Use an exact, tested, non-prerelease Traefik v3 patch tag. Never use `latest`.

No Cloudflare API token is required. Traefik uses Let's Encrypt HTTP-01 over public port 80, while you create and manage the DNS records manually.

Start Traefik:

```bash
cd /opt/traefik
sudo docker compose --env-file .env -f compose.yaml config --quiet
sudo docker compose --env-file .env -f compose.yaml pull
sudo docker compose --env-file .env -f compose.yaml up -d
sudo docker compose --env-file .env -f compose.yaml ps
sudo docker compose --env-file .env -f compose.yaml logs --tail=100 traefik
```

Verify the shared network and listening ports:

```bash
sudo docker network inspect proxy --format '{{.Name}}'
sudo ss -lntp | grep -E ':(22|80|443)\b'
curl -I http://127.0.0.1
```

Expected result:

- Traefik is healthy and publishes only 80/443.
- The `proxy` Docker network exists.
- HTTP redirects to HTTPS.
- An unmatched hostname returns Traefik's default 404.
- Port 8080 and the Traefik dashboard are not public.

Traefik mounts the Docker socket to discover future containers. Treat this as privileged host access and run only trusted workloads.

## 5. Prepare DNS

Create `A` records for future product hostnames and point them to the Elastic IP, for example:

- `api.example.com`
- `app.example.com`

Keep records **DNS only** while issuing the first certificates. Port 80 must remain publicly reachable so Let's Encrypt can request `/.well-known/acme-challenge/...`. If Cloudflare proxying is enabled later, use **SSL/TLS mode: Full (strict)**.

Verify resolution:

```bash
dig +short api.example.com
dig +short app.example.com
```

Traefik requests certificates only after the runner deploys a container with matching router labels. Each HTTPS router must use `tls.certresolver=letsencrypt`. A default 404 before product deployment is expected.

HTTP-01 issues certificates for explicit hostnames such as `api.example.com`; it does not issue wildcard certificates such as `*.example.com`. Wildcards would require DNS-01 automation and a DNS-provider token.

## 6. Install the GitHub Actions runner

Create a dedicated account and grant it Docker access:

```bash
id github-runner >/dev/null 2>&1 || \
  sudo useradd --create-home --shell /bin/bash github-runner
sudo usermod -aG docker github-runner
sudo install -d -m 0755 -o github-runner -g github-runner /opt/actions-runner
```

In GitHub open:

**Repository -> Settings -> Actions -> Runners -> New self-hosted runner -> Linux -> x64**

Run GitHub's generated download, checksum, and extraction commands as the runner account:

```bash
sudo -iu github-runner
cd /opt/actions-runner
# Paste GitHub's generated download, checksum, and extraction commands.
exit
```

Install runner OS dependencies:

```bash
sudo /opt/actions-runner/bin/installdependencies.sh
```

Configure the runner using the short-lived token shown by GitHub:

```bash
sudo -iu github-runner
cd /opt/actions-runner
./config.sh \
  --url https://github.com/OWNER/REPOSITORY \
  --token SHORT_LIVED_REGISTRATION_TOKEN \
  --name ec2-docker-host \
  --labels mem0,docker-host \
  --work _work \
  --unattended \
  --replace
exit
```

The `mem0` label is required by the current deployment workflow; `docker-host` can be used by future product workflows.

Install and start the service:

```bash
cd /opt/actions-runner
sudo ./svc.sh install github-runner
sudo ./svc.sh start
sudo ./svc.sh status
```

GitHub should show the runner as **Idle** with `self-hosted`, `Linux`, `X64`, `mem0`, and `docker-host` labels.

A self-hosted runner can execute repository code and has root-equivalent Docker access. Protect deployment branches, require workflow review, and do not run workflows from untrusted forks on this host.

## 7. Final validation and handoff

Run:

```bash
sudo ufw status verbose
sudo fail2ban-client status sshd
docker version
docker compose version
sudo docker compose \
  --env-file /opt/traefik/.env \
  -f /opt/traefik/compose.yaml \
  ps
sudo docker network inspect proxy --format '{{range .Containers}}{{println .Name}}{{end}}'
sudo ss -lntp | grep -E ':(22|80|443)\b'
cd /opt/actions-runner
sudo ./svc.sh status
```

The server is ready when:

- SSH is key-only and restricted by the AWS security group.
- UFW and fail2ban are active.
- Docker and Compose work.
- Traefik is healthy on 80/443.
- The `proxy` network exists.
- The GitHub runner is online and idle.
- No product containers are installed yet.
- Future HTTPS routers use the `letsencrypt` certificate resolver.

**Stop here.** Do not manually clone or start Mem0. The runner workflow will check out the repository, build product images, and deploy application Compose stacks onto the prepared Docker host.

## Routine host maintenance

### Update Ubuntu

```bash
sudo apt-get update
sudo apt-get upgrade -y
[ ! -f /var/run/reboot-required ] || cat /var/run/reboot-required.pkgs
```

Reboot only during a maintenance window. Docker restart policies restore Traefik automatically.

### Inspect Traefik

```bash
cd /opt/traefik
sudo docker compose --env-file .env -f compose.yaml ps
sudo docker compose --env-file .env -f compose.yaml logs --tail=200 traefik
```

### Upgrade Traefik

1. Review Traefik v3 release notes.
2. Change `TRAEFIK_IMAGE_TAG` in `/opt/traefik/.env` to an exact tested v3 patch tag.
3. Apply it:

```bash
cd /opt/traefik
sudo docker compose --env-file .env -f compose.yaml config --quiet
sudo docker compose --env-file .env -f compose.yaml pull
sudo docker compose --env-file .env -f compose.yaml up -d
sudo docker compose --env-file .env -f compose.yaml ps
```

The named ACME volume is retained. Do not use `docker compose down -v` during routine maintenance.

### Inspect runner logs

```bash
sudo journalctl -u 'actions.runner.*' --since '1 hour ago'
```

## Troubleshooting

### Traefik is unhealthy

```bash
cd /opt/traefik
sudo docker compose --env-file .env -f compose.yaml config --quiet
sudo docker compose --env-file .env -f compose.yaml logs --tail=300 traefik
sudo ss -lntp | grep -E ':(80|443)\b'
```

Check for port conflicts, an invalid v3 image tag, DNS records that do not point to the Elastic IP, or inbound TCP 80 being blocked.

### Runner is offline

```bash
cd /opt/actions-runner
sudo ./svc.sh status
sudo journalctl -u 'actions.runner.*' --since '30 minutes ago'
sudo -iu github-runner docker version
```

If Docker permission is denied, restart the runner service after confirming `github-runner` belongs to the `docker` group.

### Shared proxy network is missing

```bash
cd /opt/traefik
sudo docker compose --env-file .env -f compose.yaml up -d
sudo docker network inspect proxy
```

### Host resources are low

```bash
df -h
free -h
docker system df
uptime
```

Do not run `docker system prune --volumes` without reviewing which product data it would remove.

## Completion checklist

- [ ] Elastic IP associated and used by DNS.
- [ ] Security group exposes only restricted SSH and public 80/443.
- [ ] Termination protection and snapshots enabled.
- [ ] Ubuntu patched; unattended upgrades enabled.
- [ ] SSH keys only; UFW and fail2ban active.
- [ ] Swap configured.
- [ ] Docker Engine, Buildx, and Compose installed.
- [ ] Docker logs bounded.
- [ ] Traefik runs as a healthy Docker container with an exact v3 tag.
- [ ] DNS records are managed manually and no Cloudflare API token is stored on the host.
- [ ] Public TCP 80 remains reachable for Let's Encrypt HTTP-01.
- [ ] Traefik dashboard and non-ingress ports are private.
- [ ] Shared `proxy` network exists.
- [ ] GitHub runner is online with `mem0` and `docker-host` labels.
- [ ] Deployment branches and workflows are protected.
- [ ] No application was manually installed by this cookbook.
