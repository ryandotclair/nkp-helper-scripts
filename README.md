# NKP Helper Scripts for Prism Central

These collection of scripts are designed to inspect and clean up Kubernetes-related resources (VMs and PVCs/volume groups) in Nutanix Prism Central. All scripts talk to Prism Central via REST API.

Tested against PC 7.3

# Disclaimer

These are not officially supported scripts. Use are your own risk.

## Prerequisites

- **Bash** (scripts use `bash` and `set -uo pipefail`)
- **jq** (for JSON parsing)
- **curl** (for API calls)
- **env.vars** file in the same directory with:
  - `NUTANIX_ENDPOINT` – Prism Central URL (e.g. `https://10.0.0.1:9440`)
  - `NUTANIX_USER` – Prism Central username (e.g. `admin`)
  - `NUTANIX_PASSWORD` – Prism Central password

Example `env.vars`:

```bash
export NUTANIX_ENDPOINT='https://<PC_IP>:9440'
export NUTANIX_USER='admin'
export NUTANIX_PASSWORD='yourSecretPassword!'
```

Cluster names in the scripts match VM categories: `KubernetesClusterName` or `kubernetes_cluster_name` (e.g. `mgmt-cluster`, `konnkp`).

---

## Scripts

### 1. `infrastructure-report.sh`

**Purpose:** List all VMs that have a Kubernetes cluster name and their associated PVCs (volume groups), CPU and Memory. Read-only; no deletions.

**Output:** Tree-style report:
```shell
NKP Cluster name
|_Controller Nodes
| |_VM name ( vCPU | Memory )
|   |_PVC name
|_Worker Nodes
  |_VM name ( vCPU | Memory )
    |_PVC name
```
**Usage:**

```bash
./infrastructure-report.sh
```

Use this to see which clusters/VMs/PVCs exist and to confirm the cluster name you will pass to the delete scripts.

---

### 2. `mass-delete-storage.sh`

**Purpose:** Detach and/or delete volume groups (Kubernetes PVCs) tied to powered-off VMs in a given cluster. Prism Central requires each volume group to be deleted (individually) before you can delete the VM. This automates that.

**Modes:**

- **Discover from cluster:** Find PVCs attached to powered-off VMs in a cluster, then detach and optionally delete them.
- **From file:** Use a previously saved list of volume groups (e.g. `volumes.list.tmp`) so you can run delete in a second step without re-discovering from VMs.

**Usage:**

```bash
# 1) Detach only (writes volumes.list.tmp for the next step)
./mass-delete-storage.sh --cluster <cluster-name> --detach-only

# 2) Delete volume groups using the saved list (after verifying detach in Prism Central)
./mass-delete-storage.sh --volumes volumes.list.tmp

# Optional: re-discover from cluster and delete in one run (detach + delete)
./mass-delete-storage.sh --cluster <cluster-name>

```

**Recommended workflow:**

1. Run `./mass-delete-storage.sh --cluster <name> --detach-only` → detaches all PVCs for that cluster’s powered-off VMs and writes `volumes.list.tmp`.
2. In Prism Central, confirm all detach tasks are completed. You can further confirm with the `infrastructure-report.sh` script.
3. Run `./mass-delete-storage.sh --volumes volumes.list.tmp` → deletes the volume groups from the file (re-checks attachment; if already detached, skips straight to delete).
4. When ready, delete the VMs with `mass-delete-vms.sh` (see below).

**Options:**

| Option | Description |
|--------|-------------|
| `--cluster <name>` | NKP Kubernetes cluster name. Required unless using `--volumes`. |
| `--volumes <file>` | Use the volume list file outputted from `--detach-only`. |
| `--detach-only` | Only detach; do not delete. Writes `volumes.list.tmp` for a later delete run. |

**Environment (optional):** `CURL_TIMEOUT`, `DETACH_WAIT_SECONDS`, `DELAY_BETWEEN_VGS`, `DELETE_RETRIES`.

---

### 3. `mass-delete-vms.sh`

**Purpose:** Delete powered-off VMs in a given Kubernetes cluster via the Prism Central v3 API (`DELETE /api/nutanix/v3/vms/{uuid}`). Uses the same cluster filter as the storage script (`KubernetesClusterName` / `kubernetes_cluster_name`).

**Usage:**

```bash
./mass-delete-vms.sh --cluster <cluster-name>
```

The script lists the VMs it will delete, asks for confirmation (`yes`/`no`), then issues delete requests. Deletion is asynchronous (202); check Prism Central tasks for completion.

**When to run:** After the volume groups (PVCs) for those VMs have been detached and deleted with `mass-delete-storage.sh`. Deleting a VM that still has attached volume groups will fail in Prism Central.

---

## End-to-end workflow: tear down a cluster’s storage and VMs

1. **See what’s there**
   ```bash
   ./infrastructure-report.sh
   ```
   Note the cluster name (e.g. `mgmt-cluster`).

2. **Detach PVCs** (no delete yet)
   ```bash
   ./mass-delete-storage.sh --cluster mgmt-cluster --detach-only
   ```
   Confirm in Prism Central that volume groups are detached.

3. **Delete volume groups**
   ```bash
   ./mass-delete-storage.sh --volumes volumes.list.tmp
   ```

4. **Delete VMs**
   ```bash
   ./mass-delete-vms.sh --cluster mgmt-cluster
   ```
   Type `yes` when prompted.

All scripts require a valid `env.vars` in the current directory.
