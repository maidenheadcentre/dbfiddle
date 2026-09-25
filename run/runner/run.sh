#!/bin/bash
# $1 comes from the shim's own path and must never come from the dispatcher: the sudoers
# line has no argument spec, so any argument www-data passed would be permitted
eng=$1
[[ $eng =~ ^[a-z0-9._]+$ ]] || exit 1
[ -d /mnt/fire/$eng ] || exit 1
r="$SRANDOM"
zfs clone tank/fire/$eng@base tank/fire/$eng.$r 1>&2
cd /mnt/fire/$eng.$r 1>&2 || exit 1
date -u +%s > now
head -c 32 /dev/urandom > seed
cp /dev/stdin batches.json 1>&2
# must clear the rootfs: a write at or past the limit kills firecracker with SIGXFSZ,
# which reaches the dispatcher as an empty body and a 502 saying nothing
fsize=$(( $(stat -c %s rootfs.ext4) + 67108864 ))
mkdir -p firecracker-1.13/$r/root 1>&2
mv mem vmstate rootfs.ext4 firecracker-1.13/$r/root 1>&2
[ -d fiddlestats ] && cp --sparse=always /mnt/fire/fiddlestats/current.img fiddlestats && mv fiddlestats firecracker-1.13/$r/root
chown -R www-data:www-data firecracker-1.13/$r/root 1>&2
perl /mnt/fire/listener.pl firecracker-1.13/$r/root seed now batches.json output.json &
lpid=$!

jailer-1.13 --id $r \
       --exec-file /usr/local/sbin/firecracker-1.13 \
       --uid 33 \
       --gid 33 \
       --chroot-base-dir . \
       --resource-limit fsize=$fsize \
       --resource-limit no-file=128 \
       -- --api-sock /run/firecracker.socket >/dev/null &
jpid=$!

sock=firecracker-1.13/$r/root/run/firecracker.socket
for i in $(seq 1 200); do [ -S "$sock" ] && break; sleep 0.01; done
curl -sf --unix-socket "$sock" -X PUT http://localhost/snapshot/load -H 'Content-Type: application/json' \
     -d '{"snapshot_path":"vmstate","mem_backend":{"backend_type":"File","backend_path":"mem"},"resume_vm":true}' 1>&2
# response path ends when the listener has output.json; guest reboot and the
# clone teardown happen after the response is already returned. cleanup waits
# for the jailer to actually die before destroying - a destroy racing a
# just-killed firecracker loses with "dataset is busy" and leaks the clone
timeout 20 tail -s 0.02 --pid=$lpid -f /dev/null 1>&2
cat output.json
cd 1>&2
( kill $lpid $jpid 2>/dev/null ; timeout 10 tail -s 0.02 --pid=$jpid -f /dev/null ; zfs destroy tank/fire/$eng.$r ) >/dev/null 2>&1 &
