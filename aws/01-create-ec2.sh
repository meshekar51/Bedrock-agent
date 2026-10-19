#!/usr/bin/env bash
# Run in AWS CloudShell (region eu-central-1):  bash aws/01-create-ec2.sh
#
# Creates:
#   - IAM role + instance profile "bedrock-kind-lab": may ONLY call one Claude inference profile
#     (+ AmazonSSMManagedInstanceCore so you can connect with Session Manager, no SSH key)
#   - security group "bedrock-kind-lab" with NO inbound rules
#   - one Ubuntu 24.04 t3.large with IMDSv2 hop limit 3 (so pods inside kind can use the role)
#     and user-data that installs docker, kind, kubectl, aws cli and copies the lab files
set -euo pipefail

REGION="eu-central-1"
MODEL_ID="eu.anthropic.claude-sonnet-5-5"   # also set in lab/k8s/*.yaml and lab/check.sh
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.large}"
NAME="bedrock-kind-lab"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
export AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
FM_ID="${MODEL_ID#*.}"                                   # anthropic.claude-sonnet-5-5
PROFILE_ARN="arn:aws:bedrock:${REGION}:${ACCOUNT}:inference-profile/${MODEL_ID}"

existing="$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
if [[ -n "$existing" ]]; then
  echo "Instance already exists: ${existing}. Connect to it, or run aws/99-cleanup.sh first."
  exit 0
fi

# ------------------------------------------------------------------------------------------
step "1/6 Claude access check with YOUR identity (the first call also enables the model)"
status="$(aws bedrock get-foundation-model-availability --model-id "$FM_ID" \
  --query agreementAvailability.status --output text)"
echo "agreement: ${status}"
if [[ "$status" != "AVAILABLE" ]]; then
  echo "Claude is not enabled yet. Bedrock console -> Model catalog -> ${FM_ID} -> submit the Anthropic use-case form,"
  echo "wait until the status above is AVAILABLE, then run this script again."
  exit 1
fi
aws bedrock-runtime converse --model-id "$MODEL_ID" \
  --messages '[{"role":"user","content":[{"text":"Reply with OK"}]}]' \
  --query 'output.message.content[0].text' --output text

# ------------------------------------------------------------------------------------------
step "2/6 IAM role ${NAME} (Bedrock invoke for one model + Session Manager)"
if ! aws iam get-role --role-name "$NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$NAME" --query Role.Arn --output text \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
fi
aws iam put-role-policy --role-name "$NAME" --policy-name bedrock-invoke-one-model --policy-document "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InvokeViaEuInferenceProfile",
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
      "Resource": "${PROFILE_ARN}"
    },
    {
      "Sid": "FoundationModelOnlyThroughThatProfile",
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
      "Resource": "arn:aws:bedrock:*::foundation-model/${FM_ID}*",
      "Condition": {"StringLike": {"bedrock:InferenceProfileArn": "${PROFILE_ARN}"}}
    }
  ]
}
JSON
)"
aws iam attach-role-policy --role-name "$NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
if ! aws iam get-instance-profile --instance-profile-name "$NAME" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$NAME" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$NAME" --role-name "$NAME"
fi
aws iam wait instance-profile-exists --instance-profile-name "$NAME"
echo "role and instance profile ready"

# ------------------------------------------------------------------------------------------
step "3/6 security group with no inbound rules (you connect through Session Manager)"
VPC="$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
if [[ "$VPC" == "None" || -z "$VPC" ]]; then
  echo "No default VPC in ${REGION}. Create one: aws ec2 create-default-vpc"
  exit 1
fi
SG="$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${NAME}" "Name=vpc-id,Values=${VPC}" \
  --query 'SecurityGroups[0].GroupId' --output text)"
if [[ "$SG" == "None" || -z "$SG" ]]; then
  SG="$(aws ec2 create-security-group --group-name "$NAME" --vpc-id "$VPC" \
    --description "bedrock-kind-lab: no inbound, outbound only" --query GroupId --output text)"
fi
echo "vpc ${VPC}  security group ${SG}"

# ------------------------------------------------------------------------------------------
step "4/6 latest Ubuntu 24.04 AMI"
AMI="$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)"
echo "ami ${AMI}"

# ------------------------------------------------------------------------------------------
step "5/6 user-data: tools + lab files"
PAYLOAD="$(tar -czf - --exclude='__pycache__' --exclude='*.pyc' -C "$HERE/lab" . | base64 -w0)"
USERDATA="$(mktemp)"
{
  echo '#!/bin/bash'
  echo "REGION='${REGION}'"
  echo "MODEL_ID='${MODEL_ID}'"
  echo "PAYLOAD='${PAYLOAD}'"
  cat <<'EOF'
set -euxo pipefail
exec > >(tee /var/log/lab-setup.log) 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io unzip jq curl
systemctl enable --now docker
usermod -aG docker ubuntu

curl -fsSLo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64
chmod 0755 /usr/local/bin/kind

KV=v1.37.1
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KV}/bin/linux/amd64/kubectl"
curl -fsSLo /tmp/kubectl.sha256 "https://dl.k8s.io/release/${KV}/bin/linux/amd64/kubectl.sha256"
echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum -c -
install -m 0755 /tmp/kubectl /usr/local/bin/kubectl

curl -fsSLo /tmp/awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
unzip -q -o /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update

printf 'fs.inotify.max_user_watches = 524288\nfs.inotify.max_user_instances = 512\n' > /etc/sysctl.d/99-kind.conf
sysctl --system

printf 'export AWS_REGION=%s\nexport AWS_DEFAULT_REGION=%s\nexport MODEL_ID=%s\n' "$REGION" "$REGION" "$MODEL_ID" > /etc/profile.d/bedrock-lab.sh

mkdir -p /home/ubuntu/bedrock-kind-lab
echo "$PAYLOAD" | base64 -d | tar -xzf - -C /home/ubuntu/bedrock-kind-lab
chmod +x /home/ubuntu/bedrock-kind-lab/check.sh
chown -R ubuntu:ubuntu /home/ubuntu/bedrock-kind-lab
echo "lab ready $(date -u +%FT%TZ)" > /home/ubuntu/LAB_READY
EOF
} > "$USERDATA"
size="$(wc -c < "$USERDATA")"
echo "user-data ${size} bytes (limit 16384)"
[[ "$size" -lt 16384 ]] || { echo "user-data too large"; exit 1; }

# ------------------------------------------------------------------------------------------
step "6/6 launch ${INSTANCE_TYPE}"
INSTANCE_ID=""
for attempt in 1 2 3 4 5 6; do   # a new instance profile can take a few seconds to become usable
  if INSTANCE_ID="$(aws ec2 run-instances \
      --image-id "$AMI" \
      --instance-type "$INSTANCE_TYPE" \
      --iam-instance-profile "Name=${NAME}" \
      --security-group-ids "$SG" \
      --metadata-options "HttpEndpoint=enabled,HttpTokens=required,HttpPutResponseHopLimit=3" \
      --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}' \
      --user-data "file://${USERDATA}" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}}]" \
      --query 'Instances[0].InstanceId' --output text)"; then
    break
  fi
  echo "attempt ${attempt} failed, retrying in 10s (instance profile propagation)"
  sleep 10
done
[[ -n "$INSTANCE_ID" ]] || { echo "could not launch the instance"; exit 1; }
rm -f "$USERDATA"

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
echo
echo "Instance ${INSTANCE_ID} is running. Setup inside it takes about 3 minutes."
echo "Next: EC2 console -> Instances -> ${NAME} -> Connect -> Session Manager -> Connect"
echo "      (if the Connect button is grey, wait 1-2 minutes for the SSM agent to register)"
