# vHSM Deployment and Confidential Workload Tutorial

This guide deploys a vHSM instance on a Kubernetes cluster, configures it for attestation (nitride), wires the Dyneemes confidential runtime to it, and validates the full flow with a confidential pod. The dyneemes and attestation sections are validated against k0s; the vHSM sections apply to any Kubernetes distribution with the listed prerequisites.

---

## 0. Context and scope

### Deployment topologies

Two operator models exist in parallel and use the same software:

| Model | Operator | Instances | License | Workloads |
|---|---|---|---|---|
| Customer-managed customer vHSMs | enclaive | `shareddev.gtp.vhsm.enclaive.cloud`, `medicus.gtp.vhsm.enclaive.cloud`, `deutschlandplatform.gtp.vhsm.enclaive.cloud` | enclaive enterprise | Customer disk-encryption keys, customer app secrets, attestation policies |
| Platform vHSM | Codesphere | Customer's own infrastructure | 1-year enterprise license shipped separately | Codesphere platform secrets only |

The 3 customer instances are isolated per platform. Codesphere is not granted root access to the customer vHSMs; permissions are scoped per use case (see Section 3).

### Storage constraint for Dyneemes

Dyneemes supports block storage only (Rook-Ceph RBD, OpenEBS LocalPV-LVM, etc.). Filesystem-based runtimes (CephFS, NFS) cannot be enclaved with the current wrapper. Workloads needing a filesystem volume must use a different backend or stay outside the confidential runtime.

---

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| Kubernetes cluster with AMD EPYC SEV-SNP capable workers | Genoa platform tested. ASID limit is BIOS-dependent (LP1893: SEV-ES ASID space limit caps concurrent SNP guests). |
| `kubectl` and `helm` v3 | |
| `cert-manager` deployed | Used for ingress TLS. |
| Rook-Ceph deployed in the `rook-ceph` namespace | Block storage backend for confidential PVCs. |
| Nydus snapshotter running on workers | Required for in-guest image pulling. |
| `vhsm` CLI in `PATH` | https://github.com/enclaive/vhsm |
| `yq` >= 4.30 and `jq` on worker nodes | Older `yq` does not support `-p toml`. |
| `sev-snp-measure` python package, pinned | `pip install sev-snp-measure==0.0.11`. |

---

## 2. Deploy vHSM

### 2.1 Create the license secret

A 1-year license key is provided per instance via Vaultwarden.

```bash
kubectl create namespace vhsm

kubectl create secret generic vhsm-licence \
  --namespace vhsm \
  --from-literal=ENCLAIVE_LICENCE='<licence-key>'
```

For the three customer instances, use the matching license per ingress host.

### 2.2 Deploy via Helm

Chart reference: https://github.com/enclaive/vhsm-helm

For production, pin a release tag (not `nightly`). The example below is for HA Raft with 3 replicas.

```yaml
# helmfile.yaml
releases:
  - name: vhsm
    namespace: vhsm
    chart: oci://harbor.enclaive.cloud/vhsm/vhsm
    version: 0.29.2
    values:
      - fullnameOverride: vhsm

      - server:
          image:
            repository: harbor.enclaive.cloud/vhsm/vhsm
            tag: <release-tag>          # pin a release, not nightly
            pullPolicy: IfNotPresent

          updateStrategyType: RollingUpdate

          resources:
            requests: { cpu: 500m, memory: 1Gi }
            limits:   { cpu: 2,    memory: 4Gi }

          dataStorage:
            storageClass: <storage-class>
            size: 10Gi

          extraSecretEnvironmentVars:
            - envName: ENCLAIVE_LICENCE
              secretName: vhsm-licence
              secretKey: ENCLAIVE_LICENCE

          ingress:
            enabled: true
            annotations:
              cert-manager.io/cluster-issuer: <cluster-issuer>
            ingressClassName: <ingress-class>
            hosts:
              - host: <vhsm-host>       # e.g. shareddev.gtp.vhsm.enclaive.cloud
            tls:
              - hosts: [<vhsm-host>]
                secretName: vhsm-ingress-tls

          ha:
            enabled: true
            replicas: 3
            raft:
              enabled: true
              config: |
                plugin_directory = "/vault/plugins/"
                ui = true
                default_lease_ttl = "12h"
                max_lease_ttl = "168h"

                listener "tcp" {
                  tls_disable     = 1
                  address         = "[::]:8200"
                  cluster_address = "[::]:8201"
                }

                storage "raft" {
                  path = "/vault/data"
                }

                # Auto-unseal: see 2.4. Leave commented out for the first Shamir init.
                # seal "transit" {
                #   address     = "https://<seal-vhsm-host>"
                #   token       = "<unseal-token>"
                #   key_name    = "<key-name>"
                #   mount_path  = "transit/"
                #   namespace   = "<seal-namespace>"
                # }

                telemetry {
                  prometheus_retention_time = "30s"
                  disable_hostname          = true
                }

                service_registration "kubernetes" {}

          podDisruptionBudget:
            maxUnavailable: 1

          authDelegator:
            enabled: false

      - injector:
          enabled: false
```

Apply with Helmfile:

```bash
helmfile apply
```

Or directly with Helm:

```bash
helm upgrade --install vhsm oci://harbor.enclaive.cloud/vhsm/vhsm \
  --version 0.29.2 \
  --namespace vhsm \
  --create-namespace \
  -f your-values.yaml \
  --wait --timeout 10m
```

### 2.3 First Shamir initialization

Initialize once on the active pod. Store the unseal keys and root token in a secure vault. They cannot be recovered.

```bash
kubectl exec -ti vhsm-0 -n vhsm -- vhsm operator init
kubectl exec -ti vhsm-0 -n vhsm -- vhsm operator unseal

# For each standby
kubectl exec -ti vhsm-<N> -n vhsm -- vhsm operator raft join http://vhsm-0.vhsm.svc.cluster.local:8200
kubectl exec -ti vhsm-<N> -n vhsm -- vhsm operator unseal

kubectl exec -ti vhsm-0 -n vhsm -- vhsm operator raft list-peers
```

### 2.4 Auto-unseal (production)

Manual Shamir unseal is acceptable for the first boot. Production should auto-unseal so that pod restarts do not require an operator.

Two patterns supported:

1. **Transit seal against another vHSM (or HashiCorp Vault) instance.** Configure the `seal "transit"` block in the `raft.config` shown above. The seal instance holds a transit key the unsealing instance uses on boot. Bootstrap order: seal instance up and unsealed first, transit engine enabled, key created, scoped token issued, then the dependent instances configured with that token.
2. **Cloud KMS seal** (AWS KMS, Azure Key Vault, GCP KMS). Use the matching `seal "awskms"` / `seal "azurekeyvault"` / `seal "gcpckms"` block. Requires cloud credentials in the pod (IRSA, workload identity, or a mounted secret).

For GovTech, the recommended pattern is option 1 with the seal instance hosted on a separate cluster with stable storage. Rotate the unseal token every 90 days.

After enabling auto-unseal, perform a migration with `vhsm operator unseal -migrate` so Raft persists the new seal type, then re-roll the StatefulSet.

### 2.5 Enable audit logging

```bash
kubectl exec -ti vhsm-0 -n vhsm -- vhsm audit enable file file_path=/vault/audit/audit.log
```

Persist the audit log directory via an extra volume on the StatefulSet or ship the file to a SIEM. Without audit logging, no record of authentication or secret access exists.

### 2.6 Configure auth methods

Human admins use userpass; service workloads use kubernetes auth.

```bash
export VAULT_ADDR=https://<vhsm-host>
vhsm login   # paste root token

vhsm auth enable userpass

vhsm auth enable kubernetes
vhsm write auth/kubernetes/config \
  kubernetes_host="https://<k8s-api>:6443" \
  kubernetes_ca_cert=@<cluster-ca.pem>
```

Pattern for the Codesphere engine and any in-cluster app that consumes vHSM: bind a Kubernetes ServiceAccount in the consumer namespace to a vHSM policy that allows the relevant paths. Reference: https://developer.hashicorp.com/vault/docs/auth/kubernetes.

### 2.7 First admin user, then revoke root

```bash
cat > admin-policy.hcl <<'EOF'
path "*" {
  capabilities = ["sudo", "create", "read", "update", "delete", "list"]
}
EOF
vhsm policy write admin admin-policy.hcl

vhsm write auth/userpass/users/<admin-username> \
  password=<admin-password> \
  token_policies="admin"

# Verify
vhsm login -method=userpass username=<admin-username>

# Then revoke the root token so it stops being a long-lived god credential
vhsm token revoke <root-token>
```

> At this point vHSM is operational. You can now manage users, create namespaces, and store secrets.

### 2.8 Multi-instance notes

Each GovTech instance is a separate Helm release with its own license, ingress host, namespace plan, and seal configuration. They share the same procedure but no state.

| Instance | Ingress | Operator | Notes |
|---|---|---|---|
| `shareddev.gtp.vhsm.enclaive.cloud` | enclaive | Shared dev for vendors | First instance provisioned; semi-admin user issued to Codesphere |
| `medicus.gtp.vhsm.enclaive.cloud` | enclaive | Medicus platform | |
| `deutschlandplatform.gtp.vhsm.enclaive.cloud` | enclaive | DLP platform | |

---

## 3. Namespace strategy

vHSM namespaces are not the same as Kubernetes namespaces. They are vHSM-internal isolation boundaries with independent policies, audit scope, and mount tables.

The agreed convention for GovTech maps one vHSM namespace to one Kubernetes namespace, with paths inside the vHSM namespace separating concerns. Customer secrets and disk-encryption keys coexist under the same vHSM namespace; access is differentiated by policy at the path level.

Per-namespace path plan:

```
<vhsm-ns>/
  buckypaper/
    workloads/<workload-id>/disk/<pvc-id>      <- disk encryption keys, populated by attestation
    workloads/<workload-id>/<key>              <- static workload secrets
  appsecrets/
    <app>/<key>                                <- customer or platform app secrets, pushed via kubernetes auth
  pki/
    root/
    intermediate/
```

The Codesphere engine writes into `appsecrets/...` via the kubernetes auth method with a policy scoped to that subtree. Attestation-bound dyneemes workloads read `buckypaper/...` after the nitride flow completes.

---

## 4. Deploy Dyneemes

### 4.1 Namespace and S3 credentials secret

```bash
kubectl create namespace dyneemes

kubectl create secret generic dyneemes-s3-credentials \
  --namespace dyneemes \
  --from-literal=accessKey='<s3-access-key>' \
  --from-literal=secretKey='<s3-secret-key>'
```

### 4.2 Install the chart

The values file pins artifact SHA256 hashes from the buckypaper-os-builder pipeline. Adjust to your environment before applying.

```bash
helm upgrade --install dyneemes oci://harbor.enclaive.cloud/dyneemes/dyneemes \
  --version 0.2.0 \
  --namespace dyneemes \
  -f values-production.yaml \
  --wait --timeout 10m
```

Reference values: https://github.com/enclaive/dyneemes-helm/blob/main/docs/values-production.yaml

### 4.3 Verify the deployment

Quick checks:

```bash
kubectl get all -n dyneemes
kubectl get sc <confidential-storage-class> -o yaml | grep -A1 parameters
kubectl get runtimeclass kata-qemu-snp
```

Full proof-of-life (artifacts in S3, runtime on every node, pod inside the guest VM): https://github.com/enclaive/dyneemes-helm/blob/main/docs/podvm-verification.md

---

## 5. Calculate the firmware measurement

The firmware measurement is a digest of OVMF, kernel, initrd, and the kernel command line. It is artifact-specific. Regenerate it after every Dyneemes artifact upgrade.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install sev-snp-measure==0.0.11

export RUN_CONFIG=/etc/kata-containers/configuration-qemu-snp.toml

eval $(yq -p toml -o json . "$RUN_CONFIG" | \
  jq -r '.hypervisor.qemu |
    "OVMF=\(.firmware)\nKERNEL=\(.kernel)\nINITRD=\(.initrd)\nVCPUS=\(.default_vcpus)"')

sev-snp-measure \
  --mode snp \
  --vcpus "$VCPUS" \
  --vcpu-type EPYC-v4 \
  --ovmf "$OVMF" \
  --kernel "$KERNEL" \
  --initrd "$INITRD" \
  --append "tsc=reliable no_timer_check rcupdate.rcu_expedited=1 i8042.direct=1 i8042.dumbkbd=1 i8042.nopnp=1 i8042.noaux=1 noreplace-smp reboot=k cryptomgr.notests net.ifnames=0 pci=lastbus=0 console=hvc0 console=hvc1 quiet panic=1 nr_cpus=4 selinux=0"
```

Reference measurement for the shipped artifacts:

```
9bb39e55b5239662b32b42eeca54b66f23791267b31799ce8dfcce9e041dd774d26bf9de643e81706a113a21bee667c4
```

Note: the kernel command line is passed as a separate `--append` argument today. A future buckypaper change compiles the cmdline into the kernel image so only kernel and initrd need to be attested.

---

## 6. Configure attestation

### 6.1 Enable nitride

```bash
export VAULT_ADDR=https://<vhsm-host>
vhsm login -method=userpass username=<admin-username>

vhsm auth enable -options=namespace=true nitride
vhsm read auth/nitride/config
```

The mount path here (`nitride`) becomes the value of `nitride.enclaive.io/mount` on the pod (Section 8). Different environments may mount it as `ratls` or another name; the annotation must match the actual mount path.

### 6.2 Register the AMD VCEK root of trust (Genoa)

```bash
wget https://kdsintf.amd.com/vcek/v1/Genoa/cert_chain -O genoa-vcek.pem
sha256sum -c <<<"e6ecc853fa56d3170a624d40851f98a1036f974b50204ea69e6aec91d777aca3  genoa-vcek.pem"

vhsm write auth/nitride/identities - <<EOF
{
  "name": "amd-sev-snp-genoa-vcek",
  "type": "platform",
  "values": {
    "firmware": ">=1.55.40",
    "root_of_trust": "$(base64 -w0 genoa-vcek.pem)"
  }
}
EOF
```

### 6.3 Register the firmware identity

```bash
vhsm write auth/nitride/identities - <<EOF
{
  "name": "dyneemes",
  "type": "firmware",
  "values": {
    "measurement": "<measurement-from-section-5>",
    "vmpl": 0
  }
}
EOF
```

### 6.4 Attestation policy

```bash
vhsm write auth/nitride/policies - <<'EOF'
{
  "name": "dyneemes",
  "identities": {
    "provider": "sev-snp-raw",
    "platform": [{ "name": "amd-sev-snp-genoa-vcek" }],
    "firmware": [{ "name": "dyneemes" }]
  }
}
EOF
```

---

## 7. Create a workload

### 7.1 Namespace and secret engines

```bash
export TARGET=<vhsm-namespace>          # one per Kubernetes namespace

vhsm namespace create "$TARGET"

vhsm secrets enable -namespace="$TARGET" buckypaper
vhsm secrets enable -namespace="$TARGET" dyneemes
vhsm secrets enable -namespace="$TARGET" pki

vhsm write -namespace="$TARGET" pki/root/generate/internal \
  common_name="${TARGET}-root" \
  ttl=8760h
```

### 7.2 Workload policy

```bash
vhsm policy write -namespace="$TARGET" enclaive-attested - <<'EOF'
path "pki/intermediate/generate/exported" { capabilities = ["update"] }
path "pki/root/sign-intermediate"         { capabilities = ["update"] }
path "buckypaper/data/*"                  { capabilities = ["read"]   }
path "dyneemes/check"                     { capabilities = ["update"] }
EOF
```

### 7.3 Register the attestation

```bash
WEBHOOK=""        # optional events webhook

vhsm write auth/nitride/attestations - <<EOF
{
  "name": "<workload-name>",
  "description": "<short description>",
  "events": "${WEBHOOK}",
  "policy": "dyneemes",
  "namespace": "${TARGET}"
}
EOF
```

The command returns a workload UUID. Use it in the pod manifest below.

```
# Example output
uuid: 7d49a956-81b8-43df-8fdd-0380d88cfa3c
```

---

## 8. Deploy the confidential pod

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <k8s-namespace>
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-data
  namespace: <k8s-namespace>
spec:
  storageClassName: <confidential-storage-class>
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: test
  namespace: <k8s-namespace>
  annotations:
    nitride.enclaive.io/vhsm:     https://<vhsm-host>
    nitride.enclaive.io/mount:    <auth-mount-path>     # match Section 6.1
    nitride.enclaive.io/provider: sev-snp-raw
    nitride.enclaive.io/workload: <workload-uuid>

    dyneemes.enclaive.io/environment-ubuntu: env
    dyneemes.enclaive.io/injector-ubuntu: |
      {
        "/secrets/key.pem":  "key",
        "/secrets/crt.pem":  "cert"
      }
    dyneemes.enclaive.io/template-env: |
      {{- with buckypaperWorkload "admin-password" "dynamic=env" }}
      {{ env "ADMIN_PASSWORD" .value }}
      {{- end }}
    dyneemes.enclaive.io/template-key: |
      {{- with pkiCa "pki/intermediate/generate/exported" "common_name=test" "ttl=7d" }}
      {{ .csr.private_key }}
      {{- end }}
    dyneemes.enclaive.io/template-cert: |
      {{- with pkiCa "pki/intermediate/generate/exported" "common_name=test" "ttl=7d" }}
      {{ .certificate }}
      {{- end }}
spec:
  # Use the SEV-SNP Kata runtime class.
  # Alternatively, add the confidential runtime webhook annotation to have
  # the runtimeClassName injected automatically.
  runtimeClassName: kata-qemu-snp
  restartPolicy: Never
  containers:
    - name: ubuntu
      image: ubuntu:noble
      volumeMounts:
        - { mountPath: /data,    name: test-data    }
        - { mountPath: /secrets, name: test-secrets }
  volumes:
    - name: test-data
      persistentVolumeClaim: { claimName: test-data }
    - name: test-secrets
      emptyDir: { medium: Memory }   # secrets are kept in RAM only
```

Annotation reference:

| Annotation | Purpose |
|---|---|
| `nitride.enclaive.io/vhsm` | Base URL of the vHSM instance the in-guest trustlet contacts |
| `nitride.enclaive.io/mount` | Auth-method mount path; must equal the value passed to `vhsm auth enable` |
| `nitride.enclaive.io/provider` | Attestation provider; `sev-snp-raw` for SEV-SNP, `local-none-debug` for non-SNP testing |
| `nitride.enclaive.io/workload` | UUID returned in Section 7.3 |
| `dyneemes.enclaive.io/injector-<container>` | Map of template name to in-container file path |
| `dyneemes.enclaive.io/environment-<container>` | Map of template name to environment variable |
| `dyneemes.enclaive.io/template-<name>` | Vault-templated content to render |

PKI templates renew via fsnotify before expiry. Static secrets without a TTL require a container restart to refresh.

```bash
kubectl apply -f confidential-pod.yaml
```

---

## 9. Verify the deployment

### 9.1 Pod inside the guest VM

The first proof: the pod is actually executing inside the kata guest, not on the host. Follow Section 3 of [podvm-verification.md](https://github.com/enclaive/dyneemes-helm/blob/main/docs/podvm-verification.md). At minimum compare `uname -r` and `cat /sys/class/dmi/id/product_name` between host and pod. The pod must return a different kernel and `KVM` respectively.

### 9.2 Injected secrets and environment

```bash
kubectl exec -it -n <k8s-namespace> test -- bash
tr '\0' '\n' < /proc/1/environ | grep ADMIN_PASSWORD
ls -Rahl /secrets/
tail -n 1000 /secrets/*.pem
df -h | grep /data
dd if=/dev/urandom of=/data/test bs=4M count=256
sha256sum /data/test
```

### 9.3 LUKS-encrypted volume

```bash
vhsm kv get -namespace="$TARGET" -mount buckypaper \
  workloads/<workload-id>/disk/pvc-<pvc-id>

kubectl get pod test -n <k8s-namespace> -o yaml | grep uid:
```

On the worker node, manually open and verify. The kubelet path is distribution-specific:

| Distribution | Kubelet pod path |
|---|---|
| k0s | `/var/lib/k0s/kubelet/pods/<pod-uid>/volumes/...` |
| upstream k8s | `/var/lib/kubelet/pods/<pod-uid>/volumes/...` |
| OpenShift (RHCOS) | `/var/lib/kubelet/pods/<pod-uid>/volumes/...` |

```bash
base64 -d <<< "<key>" | cryptsetup open <device> test
mount /dev/mapper/test /mnt
sha256sum /mnt/test     # must match the in-pod hash above
umount /mnt
cryptsetup close test
```

### 9.4 Attestation review trace

```bash
VAULT_NAMESPACE="$TARGET" vhsm list dyneemes/review
VAULT_NAMESPACE="$TARGET" vhsm read dyneemes/review/<workload-name>/<container>
```

`item_id` is the workload UUID. `spec` is the base64-encoded CreateContainer request.

### 9.5 Guest serial console (debug only)

```bash
ps aux | grep qemu
sudo socat - UNIX-CONNECT:/run/vc/vm/<sandbox-id>/console.sock
```

---

## 10. Operations runbook

### 10.1 Unseal after reboot

With auto-unseal configured (Section 2.4) no operator action is required. Without it, `vhsm operator unseal` must be run on every restart for every replica. This is why production must use auto-unseal.

### 10.2 Raft snapshot and restore

Snapshot regularly (cron Job or external scheduler):

```bash
vhsm operator raft snapshot save vhsm-snapshot-$(date +%Y%m%d).snap
```

Store snapshots off-cluster. To restore on a fresh cluster:

```bash
vhsm operator raft snapshot restore vhsm-snapshot-<date>.snap
```

Snapshot includes all data and policies but not unseal keys. The seal type must match between source and destination.

### 10.3 Add or remove a Raft member

```bash
# New member joins
vhsm operator raft join http://<active-pod>:8200

# Decommission
vhsm operator raft remove-peer <node-id>
```

### 10.4 License renewal

License is a Kubernetes Secret. Replace it and restart the StatefulSet:

```bash
kubectl create secret generic vhsm-licence -n vhsm \
  --from-literal=ENCLAIVE_LICENCE='<new-key>' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart sts vhsm -n vhsm
```

### 10.5 Token and policy rotation

- Rotate the admin user password every 90 days.
- Re-evaluate `enclaive-attested` policy after every Dyneemes upgrade if the workload's path requirements change.
- Audit which tokens still have the `admin` policy attached: `vhsm list auth/userpass/users`.

### 10.6 Audit log review

Tail the audit log on each replica or ship to a SIEM. Required for compliance scopes (ISO27001, regulated workloads).

---

## Reference commands

```bash
vhsm list auth/nitride/attestations
vhsm list auth/nitride/policies
vhsm list auth/nitride/identities/firmware
vhsm list auth/nitride/identities/platform

vhsm kv get -namespace="$TARGET" -mount buckypaper workloads/<workload-id>/<key>
vhsm policy list
vhsm namespace list
vhsm operator raft list-peers
```
