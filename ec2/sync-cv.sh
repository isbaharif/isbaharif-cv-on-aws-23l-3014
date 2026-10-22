#!/bin/bash

BUCKET="cv-23l-3014"
PREFIX="site/"
SRC_DIR="/var/cv-src"
WEB_ROOT="/var/www/html"
LOG="/var/log/cv-sync.log"

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

mkdir -p "$SRC_DIR" "$WEB_ROOT"

if aws s3 sync "s3://${BUCKET}/${PREFIX}" "$SRC_DIR/" --delete --region "$REGION" --only-show-errors \
   && cp "$SRC_DIR/style.css" "$SRC_DIR/cv.pdf" "$WEB_ROOT/" \
   && sed "s/{{HOSTED_ON}}/EC2 ${INSTANCE_ID}/" "$SRC_DIR/index.html" > "$WEB_ROOT/index.html.tmp" \
   && mv "$WEB_ROOT/index.html.tmp" "$WEB_ROOT/index.html"; then
  echo "$(date '+%Y-%m-%d %H:%M:%S %Z') sync OK instance=${INSTANCE_ID}" >> "$LOG"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S %Z') sync FAILED instance=${INSTANCE_ID}" >> "$LOG"
  exit 1
fi