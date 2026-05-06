#!/bin/bash
# =============================================================================
# VDDK Registry Setup for OpenShift MTV
# =============================================================================
# PRE-REQUISITES:
#   1. VDDK already downloaded and extracted — vmware-vix-disklib-distrib/
#      directory must exist in the same folder as this script
#      Download from: https://developer.vmware.com/web/sdk/8.0/vddk
#   2. kubeconfig available at /root/vmmig/kubeconfig
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
[ -d "vmware-vix-disklib-distrib" ] || {
  echo "ERROR: vmware-vix-disklib-distrib/ not found in $(pwd)"
  echo "       Please download and extract VDDK first."
  echo "       Download: https://developer.vmware.com/web/sdk/8.0/vddk"
  exit 1
}
echo ">>> VDDK directory found: $(pwd)/vmware-vix-disklib-distrib"

# Verify oc session is working
echo ">>> Verifying oc session..."
OC_USER=$(oc whoami 2>/dev/null) || {
  echo "ERROR: Could not connect to cluster. Check your kubeconfig."
  exit 1
}
echo "    Connected as: ${OC_USER}"

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

# Wait for operator to fully reconcile
oc wait --for=condition=Available clusteroperator/image-registry --timeout=120s

# =============================================================================
echo ""
echo ">>> Phase 2: Create ODF CephFS PVC and configure registry storage"
# =============================================================================

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

# Wait for registry operator to reconcile after storage patch
echo "Waiting for image-registry operator to reconcile..."
sleep 20
oc wait --for=condition=Available clusteroperator/image-registry --timeout=120s

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
oc get secret router-certs-default \
  -n openshift-ingress \
  -o go-template='{{index .data "tls.crt"}}' \
  | base64 -d \
  | tee /etc/pki/ca-trust/source/anchors/${HOST}.crt > /dev/null

update-ca-trust extract
echo "TLS cert trusted"


# Ensure openshift-mtv namespace exists
oc new-project openshift-mtv 2>/dev/null || oc project openshift-mtv

# Grant registry-editor so the service account can push images
oc policy add-role-to-user \
  registry-editor \
  "$(oc whoami)" \
  -n openshift-mtv

# Generate token from builder service account
TOKEN=$(oc create token builder -n openshift-mtv)

# Login with explicit authfile so podman push picks up credentials correctly
podman login \
  -u serviceaccount \
  -p "${TOKEN}" \
  --authfile /tmp/auth.json \
  "${HOST}"
echo "Podman login successful"

# =============================================================================
echo ""
echo ">>> Phase 4: Build and push VDDK image"
# =============================================================================

# Dockerfile as per official Red Hat documentation

cat > Dockerfile <<DOCKERFILE
FROM registry.access.redhat.com/ubi8/ubi-minimal
USER 1001
COPY vmware-vix-disklib-distrib /vmware-vix-disklib-distrib
RUN mkdir -p /opt
ENTRYPOINT ["cp", "-r", "/vmware-vix-disklib-distrib", "/opt"]
DOCKERFILE

# Build VDDK container image tagged for the internal registry
podman build . -t "${HOST}/openshift-mtv/vddk:latest"

# Refresh token before push — large VDDK builds can take several

TOKEN=$(oc create token builder -n openshift-mtv)
podman login \
  -u serviceaccount \
  -p "${TOKEN}" \
  --authfile /tmp/auth.json \
  "${HOST}"

# Push VDDK image to the internal registry
# Note: Do NOT push to a public registry — VMware license violation
podman push \
  --authfile /tmp/auth.json \
  "${HOST}/openshift-mtv/vddk:latest"

# Allow pods in openshift-mtv to pull the VDDK image during migrations
oc adm policy add-role-to-group \
  system:image-puller \
  system:serviceaccounts:openshift-mtv \
  -n openshift-mtv

# Verify image is accessible
echo ""
echo ">>> Verifying imagestream..."
oc get imagestream vddk -n openshift-mtv
oc get imagestreamtag vddk:latest -n openshift-mtv

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
