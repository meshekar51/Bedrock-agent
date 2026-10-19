"""k8s-doctor: collect evidence about unhealthy pods in one namespace and ask Claude on Bedrock.

Identity chain (no keys anywhere):
  Kubernetes ServiceAccount k8s-doctor  -> read-only on pods, logs, events in TARGET_NAMESPACE
  EC2 instance role bedrock-kind-lab    -> reached through IMDSv2, may only call one Claude profile
"""

from __future__ import annotations

import os
import sys
import time

import boto3
from kubernetes import client, config
from kubernetes.client.rest import ApiException

NAMESPACE = os.environ.get("TARGET_NAMESPACE", "demo")
MODEL_ID = os.environ.get("MODEL_ID", "eu.anthropic.claude-sonnet-5-5")
MAX_EVIDENCE = 15000

SYSTEM = (
    "You are a senior Kubernetes SRE. You receive kubectl evidence about one namespace. "
    "For each unhealthy pod write: Pod, Root cause (one line), Evidence (quote the exact line), "
    "Fix (exact kubectl command or YAML change), Confidence (%). "
    "Use only the evidence given. If it is not enough, say what is missing. Never invent data. "
    "Plain text, no markdown tables."
)


def is_unhealthy(pod) -> bool:
    if pod.status.phase not in ("Running", "Succeeded"):
        return True
    return any((not cs.ready) or cs.restart_count > 0 for cs in pod.status.container_statuses or [])


def describe(pod) -> list[str]:
    images = {c.name: c.image for c in pod.spec.containers}
    limits = {c.name: (c.resources.limits if c.resources and c.resources.limits else {}) for c in pod.spec.containers}
    lines = [f"pod {pod.metadata.name}: phase={pod.status.phase}"]
    for cs in pod.status.container_statuses or []:
        st = cs.state
        if st.waiting:
            now = f"waiting reason={st.waiting.reason} message={st.waiting.message or ''}"
        elif st.terminated:
            now = f"terminated reason={st.terminated.reason} exit_code={st.terminated.exit_code}"
        else:
            now = "running"
        last = ""
        if cs.last_state and cs.last_state.terminated:
            t = cs.last_state.terminated
            last = f" | last_terminated reason={t.reason} exit_code={t.exit_code}"
        lines.append(
            f"  container {cs.name}: image={images.get(cs.name)} limits={limits.get(cs.name)} "
            f"ready={cs.ready} restarts={cs.restart_count} state={now}{last}"
        )
    for cond in pod.status.conditions or []:
        if cond.status != "True":
            lines.append(f"  condition {cond.type}=False reason={cond.reason} message={cond.message}")
    return lines


def logs(v1, pod) -> str:
    for previous in (True, False):
        try:
            text = v1.read_namespaced_pod_log(pod.metadata.name, NAMESPACE, tail_lines=20, previous=previous)
            if text:
                return f"  logs ({'previous' if previous else 'current'} container):\n" + "\n".join(
                    "    " + line for line in text.strip().splitlines()[-20:]
                )
        except ApiException:
            continue
    return "  logs: none available"


def collect(v1) -> tuple[str, int]:
    pods = v1.list_namespaced_pod(NAMESPACE).items
    bad = [p for p in pods if is_unhealthy(p)]
    out = [f"namespace {NAMESPACE}: {len(pods)} pods, {len(bad)} unhealthy"]
    for pod in bad:
        out += describe(pod)
        out.append(logs(v1, pod))
    events = sorted(
        v1.list_namespaced_event(NAMESPACE).items,
        key=lambda e: e.last_timestamp or e.event_time or e.metadata.creation_timestamp,
    )[-25:]
    out.append("recent events:")
    for e in events:
        obj = e.involved_object
        out.append(f"  {e.type} {e.reason} {obj.kind}/{obj.name}: {e.message} (x{e.count or 1})")
    text = "\n".join(out)
    return text[-MAX_EVIDENCE:], len(bad)


def ask_claude(evidence: str, bedrock=None) -> tuple[str, dict, float]:
    bedrock = bedrock or boto3.client("bedrock-runtime")
    started = time.perf_counter()
    resp = bedrock.converse(
        modelId=MODEL_ID,
        system=[{"text": SYSTEM}],
        messages=[{"role": "user", "content": [{"text": "Evidence from kubectl:\n\n" + evidence}]}],
        inferenceConfig={"maxTokens": 1500},
    )
    text = "".join(block.get("text", "") for block in resp["output"]["message"]["content"])
    return text, resp["usage"], time.perf_counter() - started


def main() -> int:
    config.load_incluster_config()
    v1 = client.CoreV1Api()
    print("AWS identity:", boto3.client("sts").get_caller_identity()["Arn"])
    evidence, unhealthy = collect(v1)
    print("=" * 70, "EVIDENCE SENT TO CLAUDE", "=" * 70, evidence, sep="\n")
    if unhealthy == 0:
        print("\nNo unhealthy pods in", NAMESPACE, "- nothing to diagnose.")
        return 0
    answer, usage, seconds = ask_claude(evidence)
    print("=" * 70, f"CLAUDE DIAGNOSIS ({MODEL_ID})", "=" * 70, answer, sep="\n")
    print(f"\ntokens in/out: {usage['inputTokens']}/{usage['outputTokens']}  time: {seconds:.1f}s")
    print("DOCTOR FINISHED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
