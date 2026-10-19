#!/usr/bin/env bash
# Checks every layer of the lab in order and stops at the first broken one.
#   cd ~/bedrock-kind-lab && ./check.sh
set -uo pipefail

MODEL_ID="eu.anthropic.claude-sonnet-5-5"
export AWS_REGION="eu-central-1" AWS_DEFAULT_REGION="eu-central-1" AWS_PAGER=""
cd "$(dirname "$0")" || exit 1
pass() { printf '\033[32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m  %s\n      fix: %s\n' "$1" "$2"; exit 1; }
step() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
indent() { while IFS= read -r line; do printf '      %s\n' "$line"; done; }

step "1. EC2 host has the instance role"
arn="$(aws sts get-caller-identity --query Arn --output text 2>&1)"
if [[ "$arn" == *assumed-role/bedrock-kind-lab/* ]]; then pass "$arn"
else fail "host identity: $arn" "the instance needs instance profile bedrock-kind-lab (rerun aws/01-create-ec2.sh)"; fi

step "2. EC2 host can call Claude"
out="$(aws bedrock-runtime converse --model-id "$MODEL_ID" \
  --messages '[{"role":"user","content":[{"text":"Reply with OK"}]}]' \
  --query 'output.message.content[0].text' --output text 2>&1)"
if [[ "$out" == *OK* ]]; then pass "Claude answered: $out"
else fail "bedrock from host: $out" "AccessDenied -> check the role policy and that the model is AVAILABLE"; fi

step "3. kind cluster is up"
kubectl config use-context kind-bedrock-lab >/dev/null 2>&1 \
  || fail "no kind-bedrock-lab context" "kind create cluster --config kind-cluster.yaml --wait 120s"
if kubectl wait --for=condition=Ready node --all --timeout=90s >/dev/null 2>&1; then pass "$(kubectl get nodes --no-headers)"
else fail "node not Ready" "kubectl describe node; docker ps"; fi

step "4. a pod inside kind can call Claude (pod -> IMDSv2 -> role -> Bedrock)"
kubectl -n bedrock-lab delete pod bedrock-smoke --ignore-not-found >/dev/null 2>&1
kubectl apply -f k8s/01-bedrock-smoke.yaml >/dev/null
kubectl -n bedrock-lab wait pod/bedrock-smoke --for=jsonpath='{.status.phase}'=Succeeded --timeout=240s >/dev/null 2>&1
smoke="$(kubectl -n bedrock-lab logs bedrock-smoke 2>&1)"
printf '%s\n' "$smoke" | indent
if [[ "$smoke" == *"BEDROCK SMOKE TEST PASSED"* ]]; then pass "pod reached Bedrock with the instance role"
else fail "pod could not reach Bedrock" "Unable to locate credentials -> raise IMDS hop limit (README troubleshooting)"; fi

step "5. k8s-doctor diagnoses the broken apps"
kubectl apply -f k8s/02-broken-apps.yaml >/dev/null
for _ in $(seq 1 36); do   # wait until oom-app has been OOMKilled at least once
  r="$(kubectl -n demo get pods -l app=oom-app -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null)"
  [[ "$r" == "OOMKilled" ]] && break
  sleep 5
done
kubectl -n bedrock-lab delete job k8s-doctor --ignore-not-found >/dev/null 2>&1
kubectl apply -k k8s/doctor >/dev/null
kubectl -n bedrock-lab wait --for=condition=complete job/k8s-doctor --timeout=300s >/dev/null 2>&1
doc="$(kubectl -n bedrock-lab logs job/k8s-doctor 2>&1)"
diag="$(printf '%s\n' "$doc" | sed -n '/CLAUDE DIAGNOSIS/,$p')"
printf '%s\n' "$diag" | indent
if [[ "$diag" == *"DOCTOR FINISHED"* ]] && grep -qi "oom" <<<"$diag"; then pass "Claude diagnosed the namespace (found the OOM)"
else fail "doctor did not finish" "kubectl -n bedrock-lab logs job/k8s-doctor"; fi

printf '\n\033[1;32mALL CHECKS PASSED: kind on EC2 is talking to Amazon Bedrock\033[0m\n'
