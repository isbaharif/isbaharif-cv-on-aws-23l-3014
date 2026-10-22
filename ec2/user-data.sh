#!/bin/bash
# user-data.sh - runs once as root when the instance first boots.
# 1) install and start Apache  2) install sync-cv.sh  3) run it once
# 4) schedule it every 2 minutes with a systemd timer (AL2023 has no cron).
set -x
dnf install -y httpd
systemctl enable --now httpd

# Install the sync script (same content as ec2/sync-cv.sh in the repo)
cat > /usr/local/bin/sync-cv.sh <<'SCRIPT'
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
SCRIPT
chmod 755 /usr/local/bin/sync-cv.sh

# Run the sync once now
/usr/local/bin/sync-cv.sh

# systemd service + timer: run the sync every 2 minutes
cat > /etc/systemd/system/cv-sync.service <<'UNIT'
[Unit]
Description=Sync CV from S3 into the web root

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-cv.sh
UNIT

cat > /etc/systemd/system/cv-sync.timer <<'UNIT'
[Unit]
Description=Run cv-sync every 2 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now cv-sync.timer