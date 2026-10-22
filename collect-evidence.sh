#!/bin/bash

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <bucket-name> <ec2-address> <lambda-address>"
  exit 1
fi

BUCKET="$1"
EC2_ADDR="$2"
LAMBDA_ADDR="$3"

ROLL="23l-3014"
EC2_ROLE="cv-ec2-role-${ROLL}"
LAMBDA_ROLE="cv-lambda-role-${ROLL}"
INSTANCE_NAME="cv-ec2-${ROLL}"
FUNCTION="cv-func-${ROLL}"
LOG_GROUP="/aws/lambda/${FUNCTION}"
OUT="evidence.txt"

case "$EC2_ADDR" in http://*|https://*) ;; *) EC2_ADDR="http://${EC2_ADDR}" ;; esac
case "$LAMBDA_ADDR" in http://*|https://*) ;; *) LAMBDA_ADDR="https://${LAMBDA_ADDR}" ;; esac
EC2_ADDR="${EC2_ADDR%/}"
LAMBDA_ADDR="${LAMBDA_ADDR%/}"

section() {
  echo "" >> "$OUT"
  echo "== $1 ==" >> "$OUT"
}

run() {
  echo "\$ $*" >> "$OUT"
  if ! "$@" >> "$OUT" 2>&1; then
    echo "!! command failed: $*" >> "$OUT"
  fi
}

probe() {
  local label="$1" url="$2" result
  result=$(curl -s -o /dev/null --max-time 15 -w "%{http_code} %{content_type}" "$url")
  if [ $? -ne 0 ] && [ -z "$result" ]; then
    result="!! curl failed"
  fi
  printf "%-18s %-70s %s\n" "$label" "$url" "$result" >> "$OUT"
}

{
  echo "Evidence for roll number ${ROLL}"
  echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Bucket: ${BUCKET}"
  echo "EC2 address: ${EC2_ADDR}"
  echo "Lambda address: ${LAMBDA_ADDR}"
} > "$OUT"

section "caller"
run aws sts get-caller-identity --query Account --output text

section "public-access"
run aws s3api get-public-access-block --bucket "$BUCKET"

section "versioning"
run aws s3api get-bucket-versioning --bucket "$BUCKET"

section "objects"
run aws s3 ls "s3://${BUCKET}/site/" --recursive

section "ec2-policy"
EC2_POLICY=$(aws iam list-role-policies --role-name "$EC2_ROLE" --query 'PolicyNames[0]' --output text 2>/dev/null)
if [ -n "$EC2_POLICY" ] && [ "$EC2_POLICY" != "None" ]; then
  run aws iam get-role-policy --role-name "$EC2_ROLE" --policy-name "$EC2_POLICY"
else
  echo "!! could not find an inline policy on ${EC2_ROLE}" >> "$OUT"
fi

section "lambda-policy"
run aws iam list-attached-role-policies --role-name "$LAMBDA_ROLE"
LAMBDA_POLICY=$(aws iam list-role-policies --role-name "$LAMBDA_ROLE" --query 'PolicyNames[0]' --output text 2>/dev/null)
if [ -n "$LAMBDA_POLICY" ] && [ "$LAMBDA_POLICY" != "None" ]; then
  run aws iam get-role-policy --role-name "$LAMBDA_ROLE" --policy-name "$LAMBDA_POLICY"
else
  echo "!! could not find an inline policy on ${LAMBDA_ROLE}" >> "$OUT"
fi

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${INSTANCE_NAME}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)

section "security-group"
SG_IDS=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text 2>/dev/null)
if [ -n "$SG_IDS" ] && [ "$SG_IDS" != "None" ]; then
  run aws ec2 describe-security-groups --group-ids $SG_IDS \
    --query 'SecurityGroups[].{GroupId:GroupId,GroupName:GroupName,Inbound:IpPermissions}'
else
  echo "!! could not find the security group of ${INSTANCE_NAME}" >> "$OUT"
fi

section "instance"
if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
  run aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].{InstanceId:InstanceId,Type:InstanceType,State:State.Name,PublicIp:PublicIpAddress,HttpTokens:MetadataOptions.HttpTokens,InstanceProfile:IamInstanceProfile.Arn}'
else
  echo "!! no running instance named ${INSTANCE_NAME}" >> "$OUT"
fi

section "endpoints"
printf "%-18s %-70s %s\n" "TARGET" "URL" "STATUS CONTENT-TYPE" >> "$OUT"
probe "ec2 /"            "${EC2_ADDR}/"
probe "ec2 /style.css"   "${EC2_ADDR}/style.css"
probe "ec2 /cv.pdf"      "${EC2_ADDR}/cv.pdf"
probe "lambda /"         "${LAMBDA_ADDR}/"
probe "lambda /style.css" "${LAMBDA_ADDR}/style.css"
probe "lambda /cv.pdf"   "${LAMBDA_ADDR}/cv.pdf"
probe "lambda /anything" "${LAMBDA_ADDR}/anything"
probe "s3 direct"        "https://${BUCKET}.s3.amazonaws.com/site/index.html"
echo "Footer on EC2:    $(curl -s --max-time 15 "${EC2_ADDR}/" | grep -o 'Hosted on:[^<]*')" >> "$OUT"
echo "Footer on Lambda: $(curl -s --max-time 15 "${LAMBDA_ADDR}/" | grep -o 'Hosted on:[^<]*')" >> "$OUT"

section "lambda-logs"
run aws logs tail "$LOG_GROUP" --since 1h --format short

section "log-retention"
run aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
  --query 'logGroups[].{logGroupName:logGroupName,retentionInDays:retentionInDays}'

echo "DONE"