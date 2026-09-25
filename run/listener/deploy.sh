#!/bin/bash
# install by rename, never an in-place write: a request mid-deploy must see a whole file
set -euo pipefail
cd "$(dirname "$0")"

host=root@192.168.43.2

scp listener.pl "$host":/mnt/fire/.listener.pl.new

ssh "$host" '
set -euo pipefail
chmod 644 /mnt/fire/.listener.pl.new
perl -c /mnt/fire/.listener.pl.new
# keep the outgoing copy - the rollback is a single rename back
[ -f /mnt/fire/listener.pl ] && cp -a /mnt/fire/listener.pl /mnt/fire/listener.pl.prev
mv /mnt/fire/.listener.pl.new /mnt/fire/listener.pl
ls -l /mnt/fire/listener.pl /mnt/fire/listener.pl.prev 2>/dev/null || true
md5sum /mnt/fire/listener.pl
'
