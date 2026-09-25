#!/bin/bash
# install by rename, never an in-place write: a request mid-deploy must see a whole file
set -euo pipefail
cd "$(dirname "$0")"

host=root@192.168.43.2

scp run.sh "$host":/mnt/fire/.run.sh.new

ssh "$host" '
set -euo pipefail
chown root:root /mnt/fire/.run.sh.new
chmod 700 /mnt/fire/.run.sh.new
bash -n /mnt/fire/.run.sh.new
# keep the outgoing copy - the rollback is a single rename back
[ -f /mnt/fire/run.sh ] && cp -a /mnt/fire/run.sh /mnt/fire/run.sh.prev
mv /mnt/fire/.run.sh.new /mnt/fire/run.sh
ls -l /mnt/fire/run.sh /mnt/fire/run.sh.prev 2>/dev/null || true
md5sum /mnt/fire/run.sh
'
