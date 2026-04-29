# K8S Dashboard — Full Documentation

> Source: https://modelo-dashboard-k8s-preprod.septeo.fr/docs
> Captured on 2026-04-28 (SSO authentication required — Azure AD / Septeo account)

---

## Overview

**K8S Dashboard** (Septeo) — unified interface for monitoring, debugging, and operating Kubernetes clusters.

Core features:
- **Real-time monitoring**: pods, services, deployments, and events
- **Live logs**: real-time log streaming
- **Interactive shell**: WebSocket terminal inside pods
- **Port-forwarding**: local tunnel to cluster pods
- **Administration**: group, user, namespace, and kubeconfig management

---

## SSO Login

Authentication uses the Septeo account via **Azure AD** (Microsoft OAuth2). No separate password required.

### Login flow
1. **Open the dashboard** — navigate to the URL in a browser
2. **Sign in with SSO** — click the button, authenticate with Microsoft credentials
3. **Namespace access** — only namespaces assigned to the user's group are visible

> **First login**: the account is created automatically but without a group. An admin must assign the user to a group.

---

## Home Page

List of accessible namespaces. Click a namespace to open its dashboard.

| Feature | Description |
|---|---|
| Instant search | Filter namespaces by name via the search bar |
| Alphabetical sort | Click the "Namespace" header to toggle A-Z / Z-A |
| Groups | Only namespaces assigned to the user's group by an admin are visible |

---

## Namespace Dashboard

Main view. Displays the full state of a namespace with **four tabs**: Pods, Jobs, Services, Deployments.

### Header bar

| Button | Action |
|---|---|
| **Back** | Return to the namespace list |
| **Kubeconfig** | Download the kubeconfig file (needed for `kubectl port-forward`) |
| **Refresh** | Force reload (auto-refresh every ~30s) |

### Key Performance Indicators (KPI)

| KPI | Description |
|---|---|
| Total pods | All pods in the namespace |
| Pods in error | Pods not in Running state (excluding Succeeded) |
| Restarts | Cumulative total of restarts |
| App version | Docker image tag or Helm version |
| Last deploy | Time since the last deployment |
| Services | Number of Kubernetes services |

---

## Pods Tab

Split into **Application Pods** and **Database / Cache** (auto-detected).
Sortable, filterable table: Name, Status, Ready, Restarts, Age, Port-forward, Actions.

### Port-forward

`:PORT` buttons on each Running pod with exposed ports. Clicking copies the command to clipboard.

### Per-pod actions

| Action | Availability | Description |
|---|---|---|
| **Logs** | All | Last 200 lines of pod logs |
| **Live** | All (Running pod) | Real-time streaming with LIVE badge |
| **Describe** | All | Detailed description: events, conditions, volumes, etc. |
| **Shell** | Group-dependent | Interactive terminal inside the pod (Running only) |

---

## Jobs Tab

Columns: Name, Status, Completions, Duration, Age, Owner.
Actions: **Logs** and **Describe**. Logs work even after pod deletion.

---

## Output Window

Modal displayed when launching an action (Logs, Live, Describe).

| Button | Action |
|---|---|
| **Stop** | Stops the running command |
| **Copy** | Copies all output to clipboard |
| **Clear** | Empties the window content |
| **Close** | Closes (cancels command if active) |

Auto-scroll follows new lines. Scrolling up manually disables it; it resumes when scrolling back to the bottom.

---

## Shell Terminal

Interactive terminal directly inside a pod, from the browser via WebSocket.

### Procedure
1. **Pod in Running state** — check the green badge in the Pods tab
2. **Click Shell** — an xterm terminal opens. Available commands: `ls`, `cat`, `env`, `curl`...
3. **Close** — click the X button. No history is retained.

> **Warning**: the terminal executes **inside the pod container**. Any modification affects production. Use only for diagnosis.

---

## Administration (superadmin)

**Admin** button in the navbar. Four sections:

| Section | Description |
|---|---|
| **Groups** | Create, rename, and delete user groups |
| **Kubeconfig** | Status, download, deletion, or upload of a new kubeconfig |
| **Users** | List users, assign a group, delete an account |
| **Namespaces** | Access matrix: check to authorize a group on a namespace |

> **First superadmin login**: a setup wizard guides the initial kubeconfig upload.

---

## Port-forwarding

Creates a tunnel between the local machine and a cluster pod to access a database, API, or cache locally.

```
Your machine (localhost:5432) ──tunnel──> Pod PostgreSQL (:5432)
```

### 1. Download the kubeconfig

- **Kubeconfig** button in the namespace header bar
- Place the file at: `~/.kube/config-dashboard` (macOS/Linux) or `C:\Users\You\.kube\config-dashboard` (Windows)

> This file grants cluster access. Do not share it, do not commit it to Git.

### 2. Copy the command

Pods tab > `:PORT` button > the command is copied:

```bash
kubectl port-forward -n my-namespace pod/my-pod-abc123 5432:5432
```

### 3. Run in your terminal

```bash
kubectl port-forward --kubeconfig ~/.kube/config-dashboard \
  -n my-namespace pod/my-pod-abc123 5432:5432
```

Expected output:
```
Forwarding from 127.0.0.1:5432 -> 5432
Forwarding from [::1]:5432 -> 5432
```

Connect to `localhost:5432` with your favorite tool. **Ctrl+C** to stop.

### Common ports

| Port | Service | Usage |
|---|---|---|
| `5432` | PostgreSQL | Relational database |
| `3306` | MySQL / MariaDB | Relational database |
| `27017` | MongoDB | NoSQL database |
| `6379` | Redis | Cache and message queue |
| `9200` | Elasticsearch | Search engine |
| `8080` | HTTP API | Application backend |
| `3000` | HTTP API | Node.js backend, etc. |

---

## Installing kubectl

Official Kubernetes CLI tool. Required for port-forwarding.

### macOS

**Option A — Homebrew (recommended)**:
```bash
brew install kubectl
```

**Option B — Manual (Apple Silicon)**:
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/darwin/arm64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

Intel Mac: replace `arm64` with `amd64`.

**Verification**:
```bash
kubectl version --client
```

---

## Troubleshooting

Common errors during port-forwarding:

### `error: unable to forward port because pod is not running`

The pod is not Running. Check the badge in the dashboard. Check its logs or describe.

### `bind: address already in use`

Local port already taken. Change the local port:
```bash
kubectl port-forward ... 15432:5432  # connect to localhost:15432 instead
```

### `The connection to the server was refused`

Invalid or expired kubeconfig. Re-download via the **Kubeconfig** button in the dashboard.

### `error: You must be logged in to the server`

Same causes. Download a new kubeconfig.

### Port-forward drops after a few minutes

Normal behavior when the connection is idle. Restart or use a loop:
```bash
while true; do
  kubectl port-forward --kubeconfig ~/.kube/config-dashboard \
    -n my-namespace pod/my-pod 5432:5432
  sleep 2
done
```

### `Unable to connect to the server: dial tcp: lookup ...`

The machine cannot reach the API server. Check network connectivity / VPN.

---

> **Need help?** Contact the infrastructure team or a dashboard superadmin.
