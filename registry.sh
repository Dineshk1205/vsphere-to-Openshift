#!/bin/bash
# =============================================================================
# VDDK Registry Setup for OpenShift MTV
# OCP 4.21 | ODF CephFS | Bare Metal
# =============================================================================
# PRE-REQUISITES:
#   1. VDDK already downloaded and extracted — vmware-vix-disklib-distrib/
#      directory must exist in the same folder as this script
#      Download from: https://developer.vmware.com/web/sdk/8.0/vddk
#   2. kubeconfig available at /root/auth/kubeconfig
#   3. oc and podman binaries installed on this host
#   4. ODF operator installed with a healthy StorageCluster
# =============================================================================

set -euo pipefail

# --- EDIT THESE IF NEEDED ---
KUBECONFIG_PATH="/root/vmmig/kubeconfig"
STORAGE_CLASS="ocs-storagecluster-cephfs"
# ----------------------------

export KUBECONFIG="${KUBECONFIG_PATH}"

# Confirm VDDK is already extracted before doing anything else
# Script will exit here if the directory is missing
[ -d "vmware-vix-disklib-distrib" ] || {
  echo "ERROR: vmware-vix-disklib-distrib/ not found in $(pwd)"
  echo "       Please download and extract VDDK first."
  echo "       Download: https://developer.vmware.com/web/sdk/8.0/vddk"
  exit 1
}
echo ">>> VDDK directory found: $(pwd)/vmware-vix-disklib-distrib"

# =============================================================================
echo ""
echo ">>> Phase 1: Enable internal image registry"
# =============================================================================

# Bare metal registry starts as Removed — switch to Managed
oc patch configs.imageregistry.operator.openshift.io cluster \
  --type merge \
  --patch '{"spec":{"managementState":"Managed"}}'

# Expose registry route so this host can push images
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --patch '{"spec":{"defaultRoute":true}}' \
  --type=merge

echo "Waiting for registry to become available..."
sleep 30
oc get clusteroperator image-registry

# =============================================================================
echo ""
echo ">>> Phase 2: Create ODF CephFS PVC and configure registry storage"
# =============================================================================

# CephFS RWX (ReadWriteMany) allows multiple registry pods
# to share the same volume — required for HA registry setup
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: image-registry-storage
  namespace: openshift-image-registry
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 100Gi
  storageClassName: ${STORAGE_CLASS}
EOF

# Wait for ODF to provision and bind the PVC
echo "Waiting for PVC to bind..."
for i in $(seq 1 24); do
  STATUS=$(oc get pvc image-registry-storage \
    -n openshift-image-registry \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  [ "${STATUS}" == "Bound" ] && echo "PVC Bound" && break
  echo "  PVC status: ${STATUS} (${i}/24)..."
  sleep 5
done
[ "${STATUS}" == "Bound" ] || { echo "ERROR: PVC did not bind. Check ODF StorageCluster."; exit 1; }

# Patch the registry to use the CephFS PVC as its storage backend
oc patch configs.imageregistry.operator.openshift.io cluster \
  --type merge \
  --patch '{"spec":{"storage":{"pvc":{"claim":"image-registry-storage"}}}}'

echo "Registry storage configured"

# =============================================================================
echo ""
echo ">>> Phase 3: Trust registry TLS cert and podman login"
# =============================================================================

# Get the registry external route hostname
HOST=$(oc get route default-route \
  -n openshift-image-registry \
  --template='{{ .spec.host }}')
echo "Registry HOST: ${HOST}"

# Extract the cluster ingress TLS cert and trust it system-wide
# Without this podman will fail with x509 certificate errors
oc get secret router-certs-default \
  -n openshift-ingress \
  -o go-template='{{index .data "tls.crt"}}' \
  | base64 -d \
  | tee /etc/pki/ca-trust/source/anchors/${HOST}.crt > /dev/null

update-ca-trust extract
echo "TLS cert trusted"

# Login using the kubeconfig bearer token — no password needed
# Use 'kubeadmin' as username — colons in username (kube:admin) cause login failure
podman login -u kubeadmin -p $(oc whoami -t) "${HOST}"

# =============================================================================
echo ""
echo ">>> Phase 4: Build and push VDDK image"
# =============================================================================

# Dockerfile as per official Red Hat documentation
# USER 1001 is required as per Red Hat MTV docs
cat > Dockerfile <<EOF
FROM registry.access.redhat.com/ubi8/ubi-minimal
USER 1001
COPY vmware-vix-disklib-distrib /vmware-vix-disklib-distrib
RUN mkdir -p /opt
ENTRYPOINT ["cp", "-r", "/vmware-vix-disklib-distrib", "/opt"]
EOF

# Create openshift-mtv namespace for the VDDK image
oc new-project openshift-mtv 2>/dev/null || true

# Build VDDK container image tagged for the internal registry
podman build . -t ${HOST}/openshift-mtv/vddk:latest

# Push VDDK image to the internal registry
# Note: Do NOT push to a public registry — VMware license violation
podman push ${HOST}/openshift-mtv/vddk:latest

# Allow pods in openshift-mtv to pull the VDDK image during migrations
oc adm policy add-role-to-group \
  system:image-puller \
  system:serviceaccounts:openshift-mtv \
  -n openshift-image-registry

# =============================================================================
echo ""
echo "============================================================"
echo "  SETUP COMPLETE"
echo "============================================================"
echo ""
echo "  Use this URL when registering the VMware provider in MTV UI:"
echo ""
echo "  image-registry.openshift-image-registry.svc:5000/openshift-mtv/vddk:latest"
echo ""
echo "  OCP Console: Migration -> Providers -> Add Provider"
echo "               -> VDDK Init Image field"
echo ""
# =============================================================================