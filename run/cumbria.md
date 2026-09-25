# install

* disable HyperThreading
* Debian 11
* create 100GB partitions on each SSD and RAID1 and ext4, mount /
* create max size partitions on each SSD and RAID1 and swap
* enable non-free for microcode

# base
```sh
apt install intel-microcode

cat > /etc/apt/apt.conf.d/01norecommend << EOF
APT::Install-Recommends "0";
APT::Install-Suggests "0";
EOF

apt install apparmor-utils apt-transport-https bash-completion bridge-utils cpufrequtils dnsutils htop iftop iotop less linux-perf man moreutils net-tools ntp parted psmisc pv rasdaemon rsync smartmontools telnet tmux tshark uuid-runtime vim vim-addon-manager vim-ctrlp vlan wget
grub-install /dev/sda
grub-install /dev/sdb
sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 vsyscall=emulate"/' /etc/default/grub
update-grub

systemctl enable --now rasdaemon

cat > /etc/vim/vimrc << EOF
runtime! debian.vim
syntax on
set showcmd
set showmatch
set ignorecase
set smartcase
set incsearch
set hidden
set noswapfile
set mouse=v
set hlsearch
EOF

cat > /etc/tmux.conf << EOF
set -g default-terminal "screen-256color"
set -g renumber-windows on
EOF

cat > /etc/default/smartmontools << EOF
start_smartd=yes
smartd_opts="--interval=1800"
EOF

cat > /etc/smartd.conf << EOF
DEVICESCAN -a -o on -S on -n standby,q -s (S/../.././02|L/../../6/03) -W 4,35,40 -m root -M test -M exec /usr/share/smartmontools/smartd-runner
EOF

cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

allow-hotplug eno1
iface eno1 inet manual

auto br0
iface br0 inet static
        bridge_ports eno1
        address 192.168.43.2/24
        gateway 192.168.43.1
EOF

cat >> /etc/ssh/sshd_config << EOF
UseDNS no
AllowUsers root
EOF

echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
echo 'kernel.yama.ptrace_scope=1' >> /etc/sysctl.conf
sysctl -p
```

# bmc
```sh
apt install ipmitool

ipmitool raw 0x30 0x45 0x01 0x01

cat > /usr/local/sbin/sel-rotate <<"EOF"
#!/bin/bash
n=$(ipmitool sel info | awk -F': *' '/^Entries/ {print $2}')
[ "${n:-0}" -ge 400 ] || exit 0
ipmitool sel elist | logger -t sel -p daemon.notice
ipmitool sel clear >/dev/null
logger -t sel -p daemon.notice "cleared $n entries"
EOF
chmod 700 /usr/local/sbin/sel-rotate
echo '*/15 * * * * root /usr/local/sbin/sel-rotate' > /etc/cron.d/sel-rotate
```

# zfs
```sh
apt install --install-recommends zfs-dkms

echo "options zfs zfs_arc_min=$((12*1024*1024*1024))" > /etc/modprobe.d/zfs.conf

shutdown -r now

zpool create -f -m /mnt tank raidz \
/dev/disk/by-path/pci-0000:03:00.0-sas-phy0-lun-0 \
/dev/disk/by-path/pci-0000:03:00.0-sas-phy1-lun-0 \
/dev/disk/by-path/pci-0000:03:00.0-sas-phy2-lun-0 \
/dev/disk/by-path/pci-0000:03:00.0-sas-phy3-lun-0 \
/dev/disk/by-path/pci-0000:03:00.0-sas-phy4-lun-0 \
/dev/disk/by-path/pci-0000:03:00.0-sas-phy5-lun-0

zfs create -o compression=lz4 tank/vms
zfs create -o compression=lz4 -o atime=off tank/fire
```

# firecracker
```sh
apt install -y --no-install-recommends docker.io

t=$(mktemp -d) && cd $t
curl -fsSLO https://github.com/firecracker-microvm/firecracker/releases/download/v1.13.2/firecracker-v1.13.2-x86_64.tgz
curl -fsSLO https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.10/x86_64/vmlinux-5.10.223
curl -fsSLO https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.13/x86_64/vmlinux-6.1.141
tar xzf firecracker-v1.13.2-x86_64.tgz
install -m 755 release-v1.13.2-x86_64/firecracker-v1.13.2-x86_64 /usr/local/sbin/firecracker-1.13
install -m 755 release-v1.13.2-x86_64/jailer-v1.13.2-x86_64 /usr/local/sbin/jailer-1.13
install -m 644 vmlinux-5.10.223 vmlinux-6.1.141 /mnt/fire/
cd / && rm -r $t
```

# apache/php
```sh
apt install apache2 php php-cli
mv /var/www/html/index.html /var/www/html/index.php
sed -i "s/^short_open_tag = Off$/short_open_tag = On/g" /etc/php/7.4/apache2/php.ini

cat > /etc/apache2/conf-enabled/security.conf <<"EOF"
<Directory />
  AllowOverride None
  Order Deny,Allow
  Deny from all
</Directory>

<Directory /var/www/html/>
  Options -Indexes
  AllowOverride None
  Order allow,deny
  allow from all
</Directory>

ServerTokens Prod
ServerSignature Off
TraceEnable Off
EOF

cat > /etc/apache2/sites-available/000-default.conf <<"EOF"
<VirtualHost *:80>
  ServerAdmin webmaster@localhost
  DocumentRoot /var/www/html
  AddDefaultCharset UTF-8

  ErrorLog ${APACHE_LOG_DIR}/error.log
  LogLevel warn
  CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

cat > /var/www/html/index.php <<"EOF"
<?
header('X-Powered-By: ');
header("Last-Modified: " . gmdate("D, d M Y H:i:s") . " GMT");
header("Cache-Control: no-store, no-cache, must-revalidate");
header("Cache-Control: post-check=0, pre-check=0", false);

$fire = $_GET['type'];
if(isset($_GET['sample'])) $fire .= '_'.$_GET['sample'];
if(!preg_match('/^[a-z0-9._]+$/', $fire)) { http_response_code(400); exit; }
exec('sudo -n -l /mnt/fire/'.$fire.'/run.sh 2>&1', $o, $rc);
if ($rc !== 0) { error_log("$fire UNKNOWN"); http_response_code(400); exit; }
error_log($fire);
$slot = null;
for ($i = 0; $i < 6; $i++) {
  $f = fopen("/run/lock/fiddle.$fire.$i", 'c');
  if ($f && flock($f, LOCK_EX | LOCK_NB)) { $slot = $f; break; }
  if ($f) fclose($f);
}
if (!$slot) { error_log("$fire BUSY"); http_response_code(503); exit; }
$p = proc_open(['sudo', '/mnt/fire/'.$fire.'/run.sh'], [ 0 => array("pipe", "r"), 1 => array("pipe", "w")], $pipes);

if (!is_resource($p)) { http_response_code(502); exit; }
fwrite($pipes[0], file_get_contents('php://input'));
fclose($pipes[0]);
$out = '';
$cap = 20;
$max = 2560 * 1024;
$t0 = time();
$deadline = $t0 + $cap + 5;
stream_set_blocking($pipes[1], false);
while (true) {
  $left = $deadline - time();
  if ($left <= 0) { error_log("$fire DEADLINE"); proc_terminate($p); http_response_code(504); exit; }
  $r = [$pipes[1]]; $w = null; $x = null;
  if (stream_select($r, $w, $x, $left) === false) break;
  $chunk = fread($pipes[1], 65536);
  if ($chunk === false) break;
  if ($chunk === '' && feof($pipes[1])) break;
  $out .= $chunk;
  if (($n = strlen($out)) > $max) { error_log("$fire OVERSIZE bytes=$n"); proc_terminate($p); http_response_code(413); exit; }
}
fclose($pipes[1]);
$rc = proc_close($p);
if ($rc !== 0 || $out === '') {
  $slow = (time() - $t0) >= $cap;
  error_log("$fire " . ($slow ? 'TIMEOUT' : 'FAILED') . " rc=$rc bytes=" . strlen($out));
  http_response_code($slow ? 504 : 502);
  exit;
}
echo $out;
?>
EOF

systemctl enable apache2
systemctl restart apache2
```

# tls
```sh
apt install ssl-cert
a2enmod ssl
a2ensite default-ssl
systemctl reload apache2
```

# firewall
```sh
cat > /etc/nftables.conf <<"EOF"
#!/usr/sbin/nft -f
table inet fiddle
flush table inet fiddle
table inet fiddle {
  chain input {
    type filter hook input priority filter; policy accept;
    tcp dport 22 ct state new meter sshlimit { ip saddr timeout 10m limit rate over 20/minute burst 20 packets } drop
    tcp dport 443 iif lo accept
    tcp dport 443 ip saddr { 18.132.169.71, 188.74.95.144/29 } accept
    tcp dport 443 drop
  }
}
EOF
systemctl enable --now nftables
```
