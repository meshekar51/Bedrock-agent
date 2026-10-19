#!/usr/bin/env bash
# Run in AWS CloudShell:  bash aws/99-cleanup.sh
# Terminates the lab instance and deletes the security group, instance profile and role.
set -euo pipefail

REGION="eu-central-1"
NAME="bedrock-kind-lab"
export AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""

ids="$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
if [[ -n "$ids" ]]; then
  echo "terminating ${ids}"
  # shellcheck disable=SC2086  # ids is a space-separated list
  aws ec2 terminate-instances --instance-ids $ids >/dev/null
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --instance-ids $ids
fi

sg="$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [[ -n "$sg" && "$sg" != "None" ]]; then
  echo "deleting security group ${sg}"
  aws ec2 delete-security-group --group-id "$sg"
fi

if aws iam get-instance-profile --instance-profile-name "$NAME" >/dev/null 2>&1; then
  aws iam remove-role-from-instance-profile --instance-profile-name "$NAME" --role-name "$NAME" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$NAME"
fi
if aws iam get-role --role-name "$NAME" >/dev/null 2>&1; then
  aws iam detach-role-policy --role-name "$NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws iam delete-role-policy --role-name "$NAME" --policy-name bedrock-invoke-one-model 2>/dev/null || true
  aws iam delete-role --role-name "$NAME"
fi
echo "cleanup done"
