#!/bin/bash

# Usage: ./network_test.sh <test>
# Required environment variables:
#   NAMESPACE
# Optional environment variables:
#   VALUES_FILE (default: "default.yaml")
#   INSTALL_CHAOS_MESH (default: "")
#   CHAOS_VALUES (default: "")
#   FRESH_INSTALL (default: "false")
#   AZTEC_DOCKER_TAG (default: current git commit)

set -eux

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Main positional parameter
TEST=${1:-}

REPO=$(git rev-parse --show-toplevel)
if [ "$(uname)" = "Linux" ] && [ "$(uname -m)" = "x86_64" ]; then
  "$REPO"/spartan/scripts/setup_local_k8s.sh
else
  echo "Not on x64 Linux, not installing k8s and helm."
fi

# Default values for environment variables
VALUES_FILE="${VALUES_FILE:-default.yaml}"
INSTALL_CHAOS_MESH="${INSTALL_CHAOS_MESH:-}"
CHAOS_VALUES="${CHAOS_VALUES:-}"
FRESH_INSTALL="${FRESH_INSTALL:-false}"
AZTEC_DOCKER_TAG=${AZTEC_DOCKER_TAG:-$(git rev-parse HEAD)}
INSTALL_TIMEOUT=${INSTALL_TIMEOUT:-30m}
CLEANUP_CLUSTER=${CLEANUP_CLUSTER:-false}
export INSTALL_CHAOS_MESH=${INSTALL_CHAOS_MESH:-true}
export INSTALL_METRICS=${INSTALL_METRICS:-true}

# Check required environment variable
if [ -z "${NAMESPACE:-}" ]; then
  echo "Environment variable NAMESPACE is required."
  exit 1
fi

# Always check for the aztec image
if ! docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -q "aztecprotocol/aztec:$AZTEC_DOCKER_TAG"; then
  echo "Aztec Docker image not found. It needs to be built with 'earthly ./yarn-project/+export-e2e-test-images' or otherwise tagged with aztecprotocol/aztec:$AZTEC_DOCKER_TAG."
  exit 1
fi

# Only check for end-to-end image if a test is specified
if [ -n "$TEST" ] && ! docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -q "aztecprotocol/end-to-end:$AZTEC_DOCKER_TAG"; then
  echo "End-to-end Docker image not found. It needs to be built with 'earthly ./yarn-project/+export-e2e-test-images' or otherwise tagged with aztecprotocol/end-to-end:$AZTEC_DOCKER_TAG."
  exit 1
fi

# Load the Docker images into kind
kind load docker-image aztecprotocol/aztec:$AZTEC_DOCKER_TAG

# If FRESH_INSTALL is true, delete the namespace
if [ "$FRESH_INSTALL" = "true" ]; then
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --wait=true --now --timeout=10m
fi

STERN_PID=""
function copy_stern_to_log() {
  stern spartan -n $NAMESPACE >$SCRIPT_DIR/network-test.log &
  STERN_PID=$!
}

function show_status_until_pxe_ready() {
  set +x   # don't spam with our commands
  sleep 15 # let helm upgrade start
  for i in {1..100}; do
    if kubectl wait pod -l app==pxe --for=condition=Ready -n "$NAMESPACE" --timeout=20s >/dev/null 2>/dev/null; then
      break # we are up, stop showing status
    fi
    # show startup status
    kubectl get pods -n "$NAMESPACE"
  done
}

handle_network_shaping() {
  if [ -n "${CHAOS_VALUES:-}" ]; then
    echo "Checking chaos-mesh setup..."

    if ! kubectl get service chaos-daemon -n chaos-mesh &>/dev/null; then
      # If chaos mesh is not installed, we check the INSTALL_CHAOS_MESH flag
      # to determine if we should install it.
      if [ "$INSTALL_CHAOS_MESH" ]; then
        echo "Installing chaos-mesh..."
        cd "$REPO/spartan/chaos-mesh" && ./install.sh
      else
        echo "Error: chaos-mesh namespace not found!"
        echo "Please set up chaos-mesh first. You can do this by running:"
        echo "cd $REPO/spartan/chaos-mesh && ./install.sh"
        exit 1
      fi
    fi

    echo "Deploying Aztec Chaos Scenarios..."
    if ! helm upgrade --install aztec-chaos-scenarios "$REPO/spartan/aztec-chaos-scenarios/" \
      --namespace chaos-mesh \
      --values "$REPO/spartan/aztec-chaos-scenarios/values/$CHAOS_VALUES" \
      --set global.targetNamespace="$NAMESPACE" \
      --wait \
      --timeout=5m; then
      echo "Error: failed to deploy Aztec Chaos Scenarios!"
      return 1
    fi

    echo "Aztec Chaos Scenarios applied successfully"
    return 0
  fi
  return 0
}
copy_stern_to_log
show_status_until_pxe_ready &

function cleanup() {
  # kill everything in our process group except our process
  trap - SIGTERM && kill -9 $(pgrep -g $$ | grep -v $$) $STERN_PID $(jobs -p) &>/dev/null || true

  if [ "$CLEANUP_CLUSTER" = "true" ]; then
    kind delete cluster || true
  fi
}
trap cleanup SIGINT SIGTERM EXIT


# if we don't have a chaos values, remove any existing chaos experiments
if [ -z "${CHAOS_VALUES:-}" ] && [ "$INSTALL_CHAOS_MESH" = "true" ]; then
  echo "Deleting existing network chaos experiments..."
  kubectl delete networkchaos --all --all-namespaces
fi

export VALUES_PATH="$REPO/spartan/aztec-network/values/$VALUES_FILE"
export DEFAULT_VALUES_PATH="$REPO/spartan/aztec-network/values.yaml"

# Load the read_values_file.sh script
source "$REPO/yarn-project/end-to-end/scripts/bash/read_values_file.sh"

## Some configuration values are set in the eth-devnet/config/config.yaml file
## and are used to generate the genesis.json file.
## We need to read these values and pass them into the eth devnet create.sh script
## so that it can generate the genesis.json and config.yaml file with the correct values.
$REPO/yarn-project/end-to-end/scripts/bash/generate_devnet_config.sh

# Install the Helm chart
helm upgrade --install spartan "$REPO/spartan/aztec-network/" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --values "$VALUES_PATH" \
  --set images.aztec.image="aztecprotocol/aztec:$AZTEC_DOCKER_TAG" \
  --wait \
  --wait-for-jobs=true \
  --timeout="$INSTALL_TIMEOUT"

kubectl wait pod -l app==pxe --for=condition=Ready -n "$NAMESPACE" --timeout=10m

# Find 3 free ports between 9000 and 10000
FREE_PORTS=$(comm -23 <(seq 9000 10000 | sort) <(ss -Htan | awk '{print $4}' | cut -d':' -f2 | sort -u) | shuf | head -n 3)

# Extract the free ports from the list
PXE_PORT=$(echo $FREE_PORTS | awk '{print $1}')
ANVIL_PORT=$(echo $FREE_PORTS | awk '{print $2}')
METRICS_PORT=$(echo $FREE_PORTS | awk '{print $3}')

if [ "$INSTALL_METRICS" = "true" ]; then
  GRAFANA_PASSWORD=$(kubectl get secrets -n metrics metrics-grafana -o jsonpath='{.data.admin-password}' | base64 --decode)
else
  GRAFANA_PASSWORD=""
fi

# Namespace variable (assuming it's set)
NAMESPACE=${NAMESPACE:-default}

# If we are unable to apply network shaping, as we cannot change existing chaos configurations, then delete existing configurations and try again
if [ "$INSTALL_CHAOS_MESH" = "true" ]; then
  if ! handle_network_shaping; then
    echo "Deleting existing network chaos experiments..."
    kubectl delete networkchaos --all --all-namespaces

    if ! handle_network_shaping; then
      echo "Error: failed to apply network shaping configuration!"
      exit 1
    fi
  fi
else
  echo "Skipping network chaos configuration (INSTALL_CHAOS_MESH=false)"
fi

# Get the values from the values file
ETHEREUM_SLOT_DURATION=$(read_values_file "ethereum.blockTime")
AZTEC_SLOT_DURATION=$(read_values_file "aztec.slotDuration")
AZTEC_EPOCH_DURATION=$(read_values_file "aztec.epochDuration")
AZTEC_EPOCH_PROOF_CLAIM_WINDOW_IN_L2_SLOTS=$(read_values_file "aztec.epochProofClaimWindow")

# Run the test if $TEST is not empty
if [ -n "$TEST" ]; then
  echo "RUNNING TEST: $TEST"
  docker run --rm --network=host \
    -v ~/.kube:/root/.kube \
    -e K8S=local \
    -e INSTANCE_NAME="spartan" \
    -e SPARTAN_DIR="/usr/src/spartan" \
    -e NAMESPACE="$NAMESPACE" \
    -e HOST_PXE_PORT=$PXE_PORT \
    -e CONTAINER_PXE_PORT=8081 \
    -e HOST_ETHEREUM_PORT=$ANVIL_PORT \
    -e CONTAINER_ETHEREUM_PORT=8545 \
    -e HOST_METRICS_PORT=$METRICS_PORT \
    -e CONTAINER_METRICS_PORT=80 \
    -e GRAFANA_PASSWORD=$GRAFANA_PASSWORD \
    -e DEBUG=${DEBUG:-""} \
    -e LOG_JSON=1 \
    -e LOG_LEVEL=${LOG_LEVEL:-"debug; info: aztec:simulator, json-rpc"} \
    -e ETHEREUM_SLOT_DURATION=$ETHEREUM_SLOT_DURATION \
    -e AZTEC_SLOT_DURATION=$AZTEC_SLOT_DURATION \
    -e AZTEC_EPOCH_DURATION=$AZTEC_EPOCH_DURATION \
    -e AZTEC_EPOCH_PROOF_CLAIM_WINDOW_IN_L2_SLOTS=$AZTEC_EPOCH_PROOF_CLAIM_WINDOW_IN_L2_SLOTS \
    aztecprotocol/end-to-end:$AZTEC_DOCKER_TAG $TEST
fi
