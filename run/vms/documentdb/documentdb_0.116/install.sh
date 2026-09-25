echo 'www-data        ALL=(ALL) NOPASSWD: /mnt/fire/documentdb_0.116/run.sh' >> /etc/sudoers
zfs create tank/fire/documentdb_0.116
cp /mnt/fire/vmlinux-5.10.223 /mnt/fire/documentdb_0.116/vmlinux.bin

<<'EOF' cat > /mnt/fire/documentdb_0.116/config.json
{
  "boot-source": {
    "kernel_image_path": "vmlinux.bin",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off random.trust_cpu=on"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "rootfs.ext4",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "vsock": {
    "guest_cid": 3,
    "uds_path": "v.sock"
  },
  "machine-config": {
    "vcpu_count": 1,
    "mem_size_mib": 2048
  }
}
EOF

<<'EOF' cat > /mnt/fire/documentdb_0.116/vsock.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <linux/vm_sockets.h>
#include <linux/random.h>

#ifndef RNDRESEEDCRNG
#define RNDRESEEDCRNG 0x5207
#endif

/* serve listens on 9001; reply on 9002 - a separate port so the host's
   output dial cannot land in serve's backlog and get reset when serve exits */
static int listen_on(unsigned port){
  int ls = socket(AF_VSOCK, SOCK_STREAM, 0);
  if(ls < 0) return -1;
  struct sockaddr_vm a; memset(&a, 0, sizeof a);
  a.svm_family = AF_VSOCK;
  a.svm_cid = VMADDR_CID_ANY;
  a.svm_port = port;
  if(bind(ls, (struct sockaddr *)&a, sizeof a) < 0) return -1;
  if(listen(ls, 2) < 0) return -1;
  return ls;
}

static ssize_t slurp(int s, char *buf, size_t cap){
  size_t off = 0; ssize_t n;
  while(off < cap && (n = read(s, buf + off, cap - off)) > 0) off += n;
  return (ssize_t)off;
}

int main(int argc, char **argv){
  if(argc < 2){ dprintf(2, "usage: %s serve|reply\n", argv[0]); return 2; }

  if(!strcmp(argv[1], "serve")){
    /* bind+listen BEFORE announcing readiness, so the snapshot pause can only
       ever land with the listener established and this process in accept() */
    int ls = listen_on(9001);
    if(ls < 0) return 1;
    int con = open("/dev/console", O_WRONLY);
    if(con >= 0){ dprintf(con, "FIDDLE-READY\n"); close(con); }
    struct { int entropy_count; int buf_size; unsigned char buf[4096]; } p;
    int s = accept(ls, NULL, NULL);
    if(s < 0) return 1;
    ssize_t n = slurp(s, (char *)p.buf, sizeof p.buf);
    close(s);
    if(n <= 0) return 1;
    p.entropy_count = (int)n * 8;
    p.buf_size = (int)n;
    int rf = open("/dev/urandom", O_WRONLY);
    if(rf < 0) return 1;
    if(ioctl(rf, RNDADDENTROPY, &p) < 0) return 1;
    if(ioctl(rf, RNDRESEEDCRNG, 0) < 0) return 1;
    close(rf);
    char tb[64];
    s = accept(ls, NULL, NULL);
    if(s < 0) return 1;
    n = slurp(s, tb, sizeof tb - 1);
    close(s);
    if(n <= 0) return 1;
    tb[n] = 0;
    struct timeval tv = { (time_t)atoll(tb), 0 };
    if(settimeofday(&tv, NULL) < 0) return 1;
    s = accept(ls, NULL, NULL);
    if(s < 0) return 1;
    char buf[65536];
    while((n = read(s, buf, sizeof buf)) > 0)
      if(write(1, buf, n) != n) return 1;
    close(s);
    close(ls);
    return 0;
  }

  if(!strcmp(argv[1], "reply")){
    int ls = listen_on(9002);
    if(ls < 0) return 1;
    int s = accept(ls, NULL, NULL);
    if(s < 0) return 1;
    char buf[65536]; ssize_t n;
    while((n = read(0, buf, sizeof buf)) > 0)
      if(write(s, buf, n) != n) return 1;
    shutdown(s, SHUT_WR);
    close(s);
    close(ls);
    return 0;
  }

  return 2;
}
EOF
gcc -O2 -static -o /mnt/fire/documentdb_0.116/vsock /mnt/fire/documentdb_0.116/vsock.c

# never write listener.pl here: /mnt/fire/listener.pl is shared by every engine

<<'EOF' cat > /mnt/fire/documentdb_0.116/run.sh
#!/bin/bash
# never pass "$@" through: the sudoers line has no argument spec, so any argument is
# permitted and the caller would be choosing the engine
exec /mnt/fire/run.sh "$(basename "$(dirname "$(readlink -f "$0")")")"
EOF

chmod 700 /mnt/fire/documentdb_0.116/run.sh

mkdir /mnt/fire/documentdb_0.116/mnt

<<'EODOCKER' cat > /mnt/fire/documentdb_0.116/DOCKERFILE
# syntax=docker/dockerfile:1.3-labs
FROM ubuntu:24.04
RUN apt-get update && apt-get install --no-install-recommends -y tmux wget curl jq ca-certificates systemd-sysv udev haveged
RUN <<'EORUN'
set -e
echo "deb https://apt.postgresql.org/pub/repos/apt noble-pgdg main" > /etc/apt/sources.list.d/pgdg.list
wget --quiet -O /etc/apt/trusted.gpg.d/pgdg.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
wget --quiet -O /etc/apt/trusted.gpg.d/mongodb.asc https://pgp.mongodb.com/server-8.0.asc
echo "deb https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" > /etc/apt/sources.list.d/mongodb.list
apt-get update
apt-get -y install postgresql-18 mongodb-mongosh-shared-openssl3
# every release bumps the minor: a bare latest would silently leave this version_code
V=$(curl -sf https://api.github.com/repos/documentdb/documentdb/releases | jq -r '.[].tag_name' | grep '^v0\.116-' | sort -V | tail -1)
[ -n "$V" ] || { echo "ABORT: no 0.116 release found"; exit 1; }
echo "documentdb release: $V"
mkdir -p /opt/documentdb
echo "$V" > /opt/documentdb/VERSION
curl -sfLO "https://github.com/documentdb/documentdb/releases/download/$V/ubuntu24.04-postgresql-18-documentdb_${V#v}_amd64.deb"
apt-get -y install ./ubuntu24.04-postgresql-18-documentdb_${V#v}_amd64.deb
rm -f ubuntu24.04-postgresql-18-documentdb_${V#v}_amd64.deb
<<'EOF' cat > /etc/postgresql/18/main/pg_ident.conf
# MAPNAME     SYSTEM-USERNAME   PG-USERNAME
map           postgres          postgres
map           root              postgres
EOF
<<'EOF' cat > /etc/postgresql/18/main/pg_hba.conf
#TYPE   DATABASE    USER        CIDR-ADDRESS          METHOD
local   all         postgres                          ident map=map
host    all         all         127.0.0.1/32          trust
host    all         all         ::1/128               trust
EOF
# pg_documentdb_extended_rum, the handler name and its create extension are one switch:
# without any of them new indexes silently stay on plain rum
<<'EOF' cat > /etc/postgresql/18/main/postgresql.conf
data_directory = '/var/lib/postgresql/18/main'
hba_file = '/etc/postgresql/18/main/pg_hba.conf'
ident_file = '/etc/postgresql/18/main/pg_ident.conf'
listen_addresses = '*'
datestyle = 'iso, dmy'
timezone = 'UTC'
logging_collector = on
max_wal_senders = 0
wal_level = minimal
fsync = off
full_page_writes = off
max_parallel_workers_per_gather = 4
shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb,pg_documentdb_extended_rum'
cron.database_name = 'postgres'
documentdb.alternate_index_handler_name = 'extended_rum'
EOF
EORUN
# stop cleanly, or the snapshot freezes the ceremony's boot mid WAL replay
RUN <<'EORUN'
set -e
pg_ctlcluster 18 main start
psql postgres postgres -c 'create extension documentdb cascade;'
psql postgres postgres -c 'create extension documentdb_extended_rum;'
psql postgres postgres -c 'select documentdb_api.create_user($json${"createUser":"fiddle","pwd":"fiddle","roles":[{"role":"readWriteAnyDatabase","db":"admin"},{"role":"clusterAdmin","db":"admin"}]}$json$);'
psql postgres postgres -c 'select extname, extversion from pg_extension order by 1;'
pg_ctlcluster 18 main stop
EORUN
# the gateway silently ignores an unknown key: take key names from the binary's strings
RUN <<'EORUN'
set -e
mkdir -p /opt/documentdb
<<'EOF' cat > /opt/documentdb/SetupConfiguration.json
{
  "NodeHostName": "localhost",
  "BlockedRolePrefixes": ["documentdb", "citus", "pg", "internal_role"],
  "PostgresPort": 5432,
  "PostgresSystemUser": "postgres",
  "PostgresDataUser": "postgres",
  "GatewayListenPort": 10260,
  "HostConfigurationWatchIntervalMs": 1000,
  "CertificateOptions": { "CertType": "PemAutoGenerated" },
  "UseLocalHost": false
}
EOF
<<'EOF' cat > /etc/systemd/system/documentdb-gateway.service
[Unit]
After=postgresql.service
[Service]
ExecStart=/opt/documentdb/documentdb_gateway /opt/documentdb/SetupConfiguration.json
[Install]
WantedBy=default.target
EOF
systemctl enable documentdb-gateway
EORUN
RUN <<'EORUN'
<<'EOF' cat > /etc/systemd/system/fiddle.service
[Unit]
After=postgresql.service documentdb-gateway.service
[Service]
ExecStart=/fiddle.sh
[Install]
WantedBy=default.target
EOF
systemctl enable fiddle
echo "root:Docker!" | chpasswd
EORUN
ENTRYPOINT ["bash"]
EODOCKER

# per-engine tag: concurrent builds on cumbria2 must never share one
DOCKER_BUILDKIT=1 docker build --no-cache -t dummy_documentdb_0.116 - < /mnt/fire/documentdb_0.116/DOCKERFILE
#docker run --rm -ti dummy_documentdb_0.116
# 1233 = 1500 - (365M free before the ceremony - 23M it takes - 75M target).
# Re-derive it; never copy a sibling's.
dd if=/dev/zero bs=1M count=1233 > /mnt/fire/documentdb_0.116/rootfs.ext4
mkfs.ext4 -m 0 /mnt/fire/documentdb_0.116/rootfs.ext4
mount -o loop /mnt/fire/documentdb_0.116/rootfs.ext4 /mnt/fire/documentdb_0.116/mnt
docker run --rm -ti -v /mnt/fire/documentdb_0.116/mnt:/my-rootfs dummy_documentdb_0.116
for d in bin etc home lib lib64 opt root sbin usr dev var; do tar c "/$d" | tar x -C /my-rootfs; done
for dir in run proc sys data; do mkdir /my-rootfs/${dir}; done
exit

# any edit to fiddle.sh or /fiddle invalidates the snapshot: re-run the ceremony
cat <<"EOF" > /mnt/fire/documentdb_0.116/mnt/fiddle.sh
#!/bin/bash
MONGO='mongodb://fiddle:fiddle@localhost:10260/test?authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true'
dd if=/dev/random count=1 bs=1
until [ -S /var/run/postgresql/.s.PGSQL.5432 ] ; do sleep 0.1 ; done
until /usr/bin/pg_isready -h localhost -p 5432 >/dev/null 2>&1 ; do sleep 0.05 ; done
# keep the warm-up read-only: whatever it does is frozen into every fiddle
echo '["select 1"]' > /tmp/warm.json
echo "warm-up: $(/fiddle /tmp/warm.json /tmp/warm.out >/dev/null 2>&1; cat /tmp/warm.out)" > /dev/console 2>&1
# poll the port with /dev/tcp, never the ping: each mongosh start takes seconds
i=0
until (exec 3<>/dev/tcp/127.0.0.1/10260) 2>/dev/null ; do
  i=$((i+1))
  if [ $i -gt 600 ] ; then echo "gateway-warmup: PORT NEVER OPENED" > /dev/console ; break ; fi
  sleep 0.1
done
exec 3>&- 2>/dev/null
# one ping, so the gateway and mongosh are warm in the snapshot. 2>&1: a failed ping
# otherwise prints an empty string, which reads like success
echo "gateway-warmup: ping=$(mongosh "$MONGO" --quiet --eval 'db.runCommand({ping:1}).ok' 2>&1 | tail -1)" > /dev/console 2>&1
sync
/vsock serve > /data/batches.json
until /usr/bin/pg_isready -h localhost -p 5432 ; do sleep 0.05 ; done
# no gateway wait, deliberately: a retry here would hide a gateway the restore broke
/fiddle
/vsock reply < /data/output.json
reboot -ff
EOF
chmod 700 /mnt/fire/documentdb_0.116/mnt/fiddle.sh

#mount -o loop /mnt/fire/documentdb_0.116/rootfs.ext4 /mnt/fire/documentdb_0.116/mnt
<<'EOC' cat > /mnt/fire/documentdb_0.116/fiddle.c
/* a failed connect writes no output.json on purpose: a postgres that did not come back
 * from the restore must 502, not serve an empty table.
 * Invalid UTF-8 becomes U+FFFD (set client_encoding makes it reachable): never transcode
 * it back to UTF-8.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <sys/wait.h>
#include <libpq-fe.h>

static void oom(void){ fputs("out of memory\n", stderr); exit(1); }

/* ---- growable string buffer ---- */

typedef struct { char *s; size_t len, cap; } sbuf;

static void sb_reserve(sbuf *b, size_t extra){
  if(b->len + extra + 1 <= b->cap) return;
  size_t cap = b->cap ? b->cap : 256;
  while(cap < b->len + extra + 1) cap *= 2;
  char *s = realloc(b->s, cap);
  if(!s) oom();
  b->s = s; b->cap = cap;
}
static void sb_putn(sbuf *b, const char *s, size_t n){
  sb_reserve(b, n);
  memcpy(b->s + b->len, s, n);
  b->len += n;
  b->s[b->len] = 0;
}
static void sb_puts(sbuf *b, const char *s){ sb_putn(b, s, strlen(s)); }
static void sb_putc(sbuf *b, char c){ sb_putn(b, &c, 1); }
static void sb_free(sbuf *b){ free(b->s); b->s = NULL; b->len = b->cap = 0; }

/* ---- JSON ---- */

static void put_utf8(sbuf *b, unsigned cp){
  char t[4];
  if(cp < 0x80){ t[0] = (char)cp; sb_putn(b, t, 1); }
  else if(cp < 0x800){
    t[0] = (char)(0xC0 | (cp >> 6));
    t[1] = (char)(0x80 | (cp & 0x3F));
    sb_putn(b, t, 2);
  } else if(cp < 0x10000){
    t[0] = (char)(0xE0 | (cp >> 12));
    t[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    t[2] = (char)(0x80 | (cp & 0x3F));
    sb_putn(b, t, 3);
  } else {
    t[0] = (char)(0xF0 | (cp >> 18));
    t[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    t[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    t[3] = (char)(0x80 | (cp & 0x3F));
    sb_putn(b, t, 4);
  }
}

static int hex4(const char *p, unsigned *v){
  *v = 0;
  for(int i = 0; i < 4; i++){
    char c = p[i];
    *v <<= 4;
    if(c >= '0' && c <= '9') *v |= (unsigned)(c - '0');
    else if(c >= 'a' && c <= 'f') *v |= (unsigned)(c - 'a' + 10);
    else if(c >= 'A' && c <= 'F') *v |= (unsigned)(c - 'A' + 10);
    else return 0;
  }
  return 1;
}

static int parse_json_string(const char **pp, sbuf *out){
  const char *p = *pp;
  if(*p != '"') return 0;
  p++;
  while(*p && *p != '"'){
    if(*p == '\\'){
      p++;
      switch(*p){
        case '"': sb_putc(out, '"'); p++; break;
        case '\\': sb_putc(out, '\\'); p++; break;
        case '/': sb_putc(out, '/'); p++; break;
        case 'b': sb_putc(out, '\b'); p++; break;
        case 'f': sb_putc(out, '\f'); p++; break;
        case 'n': sb_putc(out, '\n'); p++; break;
        case 'r': sb_putc(out, '\r'); p++; break;
        case 't': sb_putc(out, '\t'); p++; break;
        case 'u': {
          unsigned cp, lo;
          if(!hex4(p + 1, &cp)) return 0;
          p += 5;
          if(cp >= 0xD800 && cp <= 0xDBFF){
            if(p[0] != '\\' || p[1] != 'u' || !hex4(p + 2, &lo)
               || lo < 0xDC00 || lo > 0xDFFF) return 0;
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            p += 6;
          } else if(cp >= 0xDC00 && cp <= 0xDFFF) return 0;
          put_utf8(out, cp);
          break;
        }
        default: return 0;
      }
    } else {
      sb_putc(out, *p);
      p++;
    }
  }
  if(*p != '"') return 0;
  *pp = p + 1;
  return 1;
}

static const char *skip_ws(const char *p){
  while(*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
  return p;
}

/* lang is "" for SQL; never NULL */
typedef struct { char *s; size_t len; char *lang; } batch;

/* a string (SQL) or a [text, language] pair. The body is duckdb_1.4's parse_payload
   verbatim: keep it that way, as both runners read the same wire format */
static batch *parse_batches(const char *text, size_t *count){
  size_t cap = 8, n = 0;
  batch *v = malloc(cap * sizeof *v);
  if(!v) oom();
  const char *p = skip_ws(text);
  if(*p != '[') goto fail;
  p = skip_ws(p + 1);
  if(*p == ']'){ p++; goto done; }
  for(;;){
    sbuf s = {0}, l = {0};
    sb_reserve(&s, 1);
    s.s[0] = 0;   /* [""] must reach PQsendQuery NUL-terminated, not as raw malloc */
    sb_reserve(&l, 1);
    l.s[0] = 0;
    if(*p == '['){
      p = skip_ws(p + 1);
      if(!parse_json_string(&p, &s)) goto elemfail;
      p = skip_ws(p);
      if(*p != ',') goto elemfail;
      p = skip_ws(p + 1);
      if(!parse_json_string(&p, &l)) goto elemfail;
      p = skip_ws(p);
      if(*p != ']') goto elemfail;
      p++;
    } else if(!parse_json_string(&p, &s)){
      goto elemfail;
    }
    if(n == cap){
      cap *= 2;
      v = realloc(v, cap * sizeof *v);
      if(!v) oom();
    }
    v[n].s = s.s;
    v[n].len = s.len;
    v[n].lang = l.s;
    n++;
    p = skip_ws(p);
    if(*p == ','){ p = skip_ws(p + 1); continue; }
    if(*p == ']'){ p++; break; }
    goto fail;
  elemfail:
    sb_free(&s);
    sb_free(&l);
    goto fail;
  }
done:
  if(*skip_ws(p)) goto fail;
  *count = n;
  return v;
fail:
  for(size_t i = 0; i < n; i++){ free(v[i].s); free(v[i].lang); }
  free(v);
  *count = 0;
  return NULL;
}

static void json_emit_string(sbuf *out, const char *s, size_t n){
  sb_putc(out, '"');
  size_t i = 0;
  while(i < n){
    unsigned char c = (unsigned char)s[i];
    if(c == '"'){ sb_puts(out, "\\\""); i++; }
    else if(c == '\\'){ sb_puts(out, "\\\\"); i++; }
    else if(c == '\n'){ sb_puts(out, "\\n"); i++; }
    else if(c == '\r'){ sb_puts(out, "\\r"); i++; }
    else if(c == '\t'){ sb_puts(out, "\\t"); i++; }
    else if(c == '\b'){ sb_puts(out, "\\b"); i++; }
    else if(c == '\f'){ sb_puts(out, "\\f"); i++; }
    else if(c < 0x20){
      char t[8];
      snprintf(t, sizeof t, "\\u%04x", c);
      sb_puts(out, t);
      i++;
    }
    else if(c < 0x80){
      sb_putc(out, (char)c);
      i++;
    } else {
      int len = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC2 ? 2 : 0;
      int ok = len && i + (size_t)len <= n;
      for(int k = 1; ok && k < len; k++)
        ok = ((unsigned char)s[i + k] & 0xC0) == 0x80;
      if(ok){ sb_putn(out, s + i, (size_t)len); i += (size_t)len; }
      else { sb_puts(out, "\xEF\xBF\xBD"); i++; }
    }
  }
  sb_putc(out, '"');
}

/* ---- markdown ---- */

static void md_cell(sbuf *out, const char *s, size_t n){
  int line_start = 1;   /* the leading-space rule applies after \n only, not after a bare \r */
  size_t i = 0;
  while(i < n){
    char c = s[i];
    if(line_start && c == ' '){ sb_puts(out, "&numsp;"); i++; continue; }
    if(c == '\t'){ sb_puts(out, "&#9;"); i++; continue; }
    if(c == '\n'){ sb_puts(out, "<br>"); line_start = 1; i++; continue; }
    if(c == '\r'){
      sb_puts(out, "<br>");
      if(i + 1 < n && s[i + 1] == '\n'){ line_start = 1; i += 2; }
      else { line_start = 0; i++; }
      continue;
    }
    line_start = 0;
    if(c && strchr("[*/|`_<&\\", c)) sb_putc(out, '\\');
    sb_putc(out, c);
    i++;
  }
}

static void fence_block(sbuf *out, const char *text, size_t n, const char *label){
  size_t fence = 3, run = 0;
  for(size_t i = 0; i < n; i++){
    if(text[i] == '`'){ run++; if(run >= fence) fence++; }
    else run = 0;
  }
  sb_puts(out, "> ");
  for(size_t i = 0; i < fence; i++) sb_putc(out, '`');
  sb_putc(out, ' ');
  sb_puts(out, label);
  sb_puts(out, "\n> ");
  for(size_t i = 0; i < n; i++){
    sb_putc(out, text[i]);
    if(text[i] == '\n') sb_puts(out, "> ");
  }
  sb_puts(out, "\n> ");
  for(size_t i = 0; i < fence; i++) sb_putc(out, '`');
  sb_puts(out, "\n\n");
}

/* ---- language batches ---- */

static void fence_plain(sbuf *out, const char *text, size_t n, const char *label){
  size_t fence = 3, run = 0;
  for(size_t i = 0; i < n; i++){
    if(text[i] == '`'){ run++; if(run >= fence) fence++; }
    else run = 0;
  }
  for(size_t i = 0; i < fence; i++) sb_putc(out, '`');
  if(*label){ sb_putc(out, ' '); sb_puts(out, label); }
  sb_putc(out, '\n');
  sb_putn(out, text, n);
  if(n && text[n-1] != '\n') sb_putc(out, '\n');
  for(size_t i = 0; i < fence; i++) sb_putc(out, '`');
  sb_puts(out, "\n\n");
}

static long now_ms(void){
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

#define CAP (4L << 20)

/* the runner's connection string, never the user's: a batch must not choose its server */
#define MONGO_URI "mongodb://fiddle:fiddle@localhost:10260/test" \
                  "?authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true"

/* the database in MONGO_URI is part of the contract: every mongosh batch lands in test */
static char *const *lang_argv(const char *lang){
  static char *const mongosh_av[] = {
    (char *)"/usr/bin/mongosh", (char *)MONGO_URI, (char *)"--quiet", NULL
  };
  if(!strcmp(lang, "mongosh")) return mongosh_av;
  return NULL;
}

/* only a line starting with the literal "[direct: " is a prompt: never loosen it, or
   output that merely starts with '[' (most JSON) can be eaten */
static void strip_prompts(sbuf *b){
  static const char pre[] = "[direct: ";
  const size_t pl = sizeof pre - 1;
  if(!b->len) return;
  sbuf o = {0};
  size_t i = 0;
  int at_line_start = 1;
  while(i < b->len){
    if(at_line_start && b->len - i > pl && !memcmp(b->s + i, pre, pl)){
      size_t lim = i + 96 < b->len ? i + 96 : b->len;
      size_t j = i + pl, close = 0;
      while(j + 1 < lim && b->s[j] != '\n'){
        if(b->s[j] == ']' && b->s[j + 1] == ' '){ close = j; break; }
        j++;
      }
      if(close){
        size_t k = close + 2;
        int stripped = 0;
        while(k + 1 < lim && b->s[k] != '\n'){
          if(b->s[k] == '>' && b->s[k + 1] == ' '){ i = k + 2; stripped = 1; break; }
          k++;
        }
        if(stripped){
          /* continuation prompts, one "| " per line: consumed only straight after a
             primary prompt, so output that begins "| " is never touched */
          while(i + 1 < b->len && b->s[i] == '|' && b->s[i + 1] == ' ') i += 2;
          if(i < b->len && b->s[i] == '\n'){ i++; at_line_start = 1; }
          else at_line_start = 0;
          continue;
        }
      }
    }
    if(b->s[i] != '\r') sb_putc(&o, b->s[i]);
    at_line_start = (b->s[i] == '\n');
    i++;
  }
  sb_free(b);
  *b = o;
}

/* the batch goes in on stdin, never via --file or --eval: those print only the last
   expression's value and silently drop the rest */
static int run_lang_batch(const batch *b, char *const *av,
                          sbuf *so, sbuf *se, int *status, long deadline){
  int ip[2], op[2], ep[2];
  if(pipe(ip) < 0) return 0;
  if(pipe(op) < 0){ close(ip[0]); close(ip[1]); return 0; }
  if(pipe(ep) < 0){ close(ip[0]); close(ip[1]); close(op[0]); close(op[1]); return 0; }

  pid_t pid = fork();
  if(pid < 0){
    close(ip[0]); close(ip[1]); close(op[0]); close(op[1]); close(ep[0]); close(ep[1]);
    return 0;
  }
  if(pid == 0){
    dup2(ip[0], 0); dup2(op[1], 1); dup2(ep[1], 2);
    close(ip[0]); close(ip[1]); close(op[0]); close(op[1]); close(ep[0]); close(ep[1]);
    if(chdir("/tmp") != 0) _exit(126);
    execv(av[0], av);
    _exit(127);
  }
  close(ip[0]); close(op[1]); close(ep[1]);

  /* an interpreter that exits before reading its batch must not SIGPIPE the runner */
  void (*oldpipe)(int) = signal(SIGPIPE, SIG_IGN);
  size_t off = 0;
  while(off < b->len){
    ssize_t w = write(ip[1], b->s + off, b->len - off);
    if(w <= 0) break;
    off += (size_t)w;
  }
  close(ip[1]);   /* EOF is what ends the REPL */

  int done = 0, killed = 0;
  struct pollfd p[2] = { { op[0], POLLIN, 0 }, { ep[0], POLLIN, 0 } };
  while(done < 2){
    long left = deadline - now_ms();
    if(left <= 0){ kill(pid, SIGKILL); killed = 1; break; }
    int r = poll(p, 2, left > 200 ? 200 : (int)left);
    if(r < 0) break;
    for(int i = 0; i < 2; i++){
      if(p[i].fd < 0 || !(p[i].revents & (POLLIN | POLLHUP))) continue;
      char t[65536];
      ssize_t k = read(p[i].fd, t, sizeof t);
      if(k > 0){
        sbuf *d = i ? se : so;
        if(d->len < (size_t)CAP) sb_putn(d, t, (size_t)k);
      } else {
        close(p[i].fd); p[i].fd = -1; done++;
      }
    }
  }
  for(int i = 0; i < 2; i++) if(p[i].fd >= 0) close(p[i].fd);
  int st = 0;
  waitpid(pid, &st, 0);
  signal(SIGPIPE, oldpipe);
  *status = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
  return killed;
}

/* ---- postgres ---- */

/* int2, int4, int8, numeric, money: fixed system oids, so no catalog lookup */
static int align_right(Oid t){
  return t == 21 || t == 23 || t == 20 || t == 1700 || t == 790;
}

static void render_result(sbuf *md, PGresult *res){
  int nf = PQnfields(res);
  sbuf h2 = {0};
  sb_puts(md, "|");
  sb_puts(&h2, "|");
  for(int i = 0; i < nf; i++){
    const char *name = PQfname(res, i);
    size_t nl = strlen(name);
    int ar = align_right(PQftype(res, i));
    sb_putc(md, ' ');
    md_cell(md, name, nl);
    sb_puts(md, " |");
    /* the dashes count the raw name, not the escaped one */
    sb_putc(&h2, ar ? '-' : ':');
    for(size_t j = 0; j < nl; j++) sb_putc(&h2, '-');
    sb_putc(&h2, ar ? ':' : '-');
    sb_putc(&h2, '|');
  }
  sb_putc(md, '\n');
  sb_putn(md, h2.s, h2.len);
  sb_putc(md, '\n');
  sb_free(&h2);
  int nr = PQntuples(res);
  for(int r = 0; r < nr; r++){
    sb_puts(md, "|");
    for(int j = 0; j < nf; j++){
      sb_putc(md, ' ');
      if(PQgetisnull(res, r, j)) sb_puts(md, "*null*");
      else md_cell(md, PQgetvalue(res, r, j), (size_t)PQgetlength(res, r, j));
      sb_puts(md, " |");
    }
    sb_putc(md, '\n');
  }
}

static int php_space(char c){
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\0' || c == '\v';
}
static void fence_trimmed(sbuf *out, const char *s, const char *label){
  size_t n = strlen(s), b = 0;
  while(b < n && php_space(s[b])) b++;
  while(n > b && php_space(s[n - 1])) n--;
  fence_block(out, s + b, n - b, label);
}

static void drop_notice(void *arg, const char *msg){ (void)arg; (void)msg; }

/* ---- main ---- */

static char *read_file(const char *path, size_t *n){
  FILE *f = fopen(path, "rb");
  if(!f) return NULL;
  sbuf b = {0};
  sb_reserve(&b, 1);
  b.s[0] = 0;
  char t[65536];
  size_t r;
  while((r = fread(t, 1, sizeof t, f)) > 0) sb_putn(&b, t, r);
  fclose(f);
  *n = b.len;
  return b.s;
}

int main(int argc, char **argv){
  const char *inpath = argc > 1 ? argv[1] : "/data/batches.json";
  const char *outpath = argc > 2 ? argv[2] : "/data/output.json";

  PGconn *conn = PQconnectdb("user=postgres");
  if(PQstatus(conn) != CONNECTION_OK){
    fputs("Could not connect to the server\n", stderr);
    return 1;
  }
  PQsetNoticeProcessor(conn, drop_notice, NULL);
  /* documentdb_api on the search_path is deliberate, and is why this corpus cannot be
     byte-compared against the postgres family's */
  PQclear(PQexec(conn, "set search_path to public,documentdb_api,x_tablefunc,x_pg_trgm,"
                       "x_intarray,x_hstore,x_tsm_system_rows,x_unaccent,x_ltree,"
                       "x_postgis;"));

  size_t blen = 0, nb = 0;
  char *btext = read_file(inpath, &blen);
  batch *batches = btext ? parse_batches(btext, &nb) : NULL;

  /* 15s, inside run.sh's 20s: a hung batch must leave time to return a body */
  long deadline = now_ms() + 15000;

  sbuf out = {0};
  sb_putc(&out, '[');
  for(size_t i = 0; i < nb; i++){
    sbuf md = {0};
    const char *lang = batches[i].lang;
    if(lang[0]){
      char *const *av = lang_argv(lang);
      if(!av){
        sbuf m = {0};
        sb_puts(&m, "unknown language: ");
        sb_puts(&m, lang);
        fence_block(&md, m.s, m.len, "error");
        sb_free(&m);
      } else {
        sbuf so = {0}, se = {0};
        int status = 0, killed = 0, skipped = 0;
        if(now_ms() >= deadline) skipped = 1;
        else killed = run_lang_batch(&batches[i], av, &so, &se, &status, deadline);
        strip_prompts(&so);
        if(so.len) fence_plain(&md, so.s, so.len, "");
        if(se.len) fence_block(&md, se.s, se.len, "error");
        if(skipped){
          const char *m = "not run: an earlier batch used the runner's time budget";
          fence_block(&md, m, strlen(m), "error");
        } else if(killed){
          const char *m = "batch did not finish within the runner's time budget";
          fence_block(&md, m, strlen(m), "error");
        } else if(status != 0 && !se.len){
          char m[64];
          int n = snprintf(m, sizeof m, "exited with status %d", status);
          fence_block(&md, m, (size_t)n, "error");
        }
        sb_free(&so);
        sb_free(&se);
      }
    } else if(PQsendQuery(conn, batches[i].s)){
      PGresult *res;
      /* drain to NULL always: a half-read batch would desync the next one */
      while((res = PQgetResult(conn))){
        const char *e = PQresultErrorMessage(res);
        if(e && *e){
          /* fence_block already ends in two newlines: only a fence-less result
             needs the second */
          fence_trimmed(&md, e, "error");
        } else {
          if(PQnfields(res) > 0) render_result(&md, res);
          const char *st = PQcmdStatus(res);
          if(st && *st) fence_block(&md, st, strlen(st), "status");
          else sb_putc(&md, '\n');
        }
        PQclear(res);
      }
    } else {
      const char *e = PQerrorMessage(conn);
      if(e && *e) fence_trimmed(&md, e, "error");
    }
    if(i) sb_putc(&out, ',');
    json_emit_string(&out, md.s ? md.s : "", md.len);
    sb_free(&md);
  }
  sb_putc(&out, ']');
  PQfinish(conn);

  FILE *f = fopen(outpath, "wb");
  if(!f) return 1;
  fwrite(out.s, 1, out.len, f);
  fclose(f);
  return 0;
}
EOC

cp /mnt/fire/documentdb_0.116/fiddle.c /mnt/fire/documentdb_0.116/mnt/fiddle.c
docker run --rm -v /mnt/fire/documentdb_0.116/mnt:/my-rootfs dummy_documentdb_0.116 -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends gcc libc6-dev libpq-dev && gcc -O2 -Wall -I$(pg_config --includedir) -o /my-rootfs/fiddle /my-rootfs/fiddle.c -lpq && rm /my-rootfs/fiddle.c'
chroot /mnt/fire/documentdb_0.116/mnt /usr/bin/ldd /fiddle
# built from the tag the image recorded, so the gateway and the extension are one release,
# and at x86-64-v2: cumbria2's CPU has no AVX2, so upstream's v3 build dies of SIGILL
docker run --rm -v /mnt/fire/documentdb_0.116/mnt:/my-rootfs dummy_documentdb_0.116 -c 'set -e
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends git build-essential pkg-config libssl-dev
  curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable >/dev/null
  . "$HOME/.cargo/env"
  V=$(cat /my-rootfs/opt/documentdb/VERSION)
  echo "building the gateway from $V"
  git clone --depth 1 --branch "$V" https://github.com/documentdb/documentdb /src
  cd /src/pg_documentdb_gw
  if ! grep -q "target-cpu=x86-64-v3" .cargo/config.toml ; then
    echo "ABORT: upstream rustflags line not found - the AVX2 patch would be a silent no-op" ; exit 1
  fi
  sed -i "/target-cpu=x86-64-v3/c\\rustflags = [\"-C\", \"target-cpu=x86-64-v2\"]" .cargo/config.toml
  if grep -q "x86-64-v3" .cargo/config.toml ; then echo "ABORT: v3 baseline survived the patch" ; exit 1 ; fi
  if ! grep -q "target-cpu=x86-64-v2" .cargo/config.toml ; then echo "ABORT: v2 baseline not written" ; exit 1 ; fi
  # the checks above still pass if upstream ever moves +avx2 to a line of its own
  if grep -E "^[[:space:]]*rustflags" .cargo/config.toml | grep -qi "avx" ; then
    echo "ABORT: an avx flag survived in a rustflags line" ; exit 1
  fi
  cargo build --profile=release-with-symbols
  install -m 755 target/release-with-symbols/documentdb_gateway /my-rootfs/opt/documentdb/documentdb_gateway'
chroot /mnt/fire/documentdb_0.116/mnt /usr/bin/ldd /opt/documentdb/documentdb_gateway

chroot /mnt/fire/documentdb_0.116/mnt /usr/bin/mongosh --version \
  || { echo "ABORT: no /usr/bin/mongosh in the rootfs - a mongosh batch would exit 127"; exit 1; }

# drop the image: cumbria2's root filesystem fills otherwise
docker rmi dummy_documentdb_0.116


cp /mnt/fire/documentdb_0.116/vsock /mnt/fire/documentdb_0.116/mnt/vsock
chmod 755 /mnt/fire/documentdb_0.116/mnt/vsock

umount /mnt/fire/documentdb_0.116/mnt

dumpe2fs -h /mnt/fire/documentdb_0.116/rootfs.ext4 2>/dev/null | awk '
  /^Block size:/ {bs=$3} /^Free blocks:/ {fb=$3}
  END { printf "rootfs headroom before the ceremony: %.1fM free (block size %d)\n", fb*bs/1048576, bs }'

zfs set recordsize=16K tank/fire/documentdb_0.116

cd /mnt/fire/documentdb_0.116
# per-engine log and socket: a concurrent ceremony on a shared path steals the snapshot
rm -f mem vmstate v.sock* /tmp/fc-snap-documentdb_0.116.sock /tmp/fc-snap-documentdb_0.116.log
firecracker-1.13 --api-sock /tmp/fc-snap-documentdb_0.116.sock --config-file config.json > /tmp/fc-snap-documentdb_0.116.log 2>&1 &
until grep -q FIDDLE-READY /tmp/fc-snap-documentdb_0.116.log ; do sleep 0.1 ; done
sleep 0.3
curl -sf --unix-socket /tmp/fc-snap-documentdb_0.116.sock -X PATCH http://localhost/vm -H 'Content-Type: application/json' -d '{"state":"Paused"}'
curl -sf --unix-socket /tmp/fc-snap-documentdb_0.116.sock -X PUT http://localhost/snapshot/create -H 'Content-Type: application/json' -d '{"snapshot_type":"Full","snapshot_path":"vmstate","mem_file_path":"mem"}'
kill $! || true
grep -a 'warm-up:' /tmp/fc-snap-documentdb_0.116.log || echo "WARNING: no warm-up line in the ceremony log"

# never -R: against a live engine it destroys the clones of in-flight fiddles
zfs destroy tank/fire/documentdb_0.116@base 2>/dev/null || true
zfs snapshot tank/fire/documentdb_0.116@base

gate=$(mktemp -d)
if ! mount -o loop,ro,norecovery /mnt/fire/documentdb_0.116/rootfs.ext4 "$gate"; then
  echo "ABORT: could not mount the rootfs to measure its headroom"
  exit 1
fi
free=$(df -m "$gate" | awk 'NR==2 {print $4}')
umount "$gate"; rmdir "$gate"
echo "rootfs headroom AFTER the ceremony: ${free}M free"
case "$free" in ''|*[!0-9]*)
  echo "ABORT: could not read the free space"; exit 1;;
esac
if [ "$free" -lt 50 ] || [ "$free" -gt 100 ]; then
  echo "ABORT: headroom ${free}M outside 50-100M - re-derive the dd count="
  exit 1
fi

# both surfaces in one fiddle: either alone can pass while the other is dead
read -r -d '' verify <<'VEOF' || true
["select documentdb_api.insert_one('test','t','{\"a\":1}')",
 ["db.t.find()", "mongosh"]]
VEOF
out=$(printf '%s' "$verify" | /mnt/fire/documentdb_0.116/run.sh) || true
printf '%s\n' "$out"
# run.sh has no meaningful exit status: assert on the body
[ -n "$out" ] || { echo "ABORT: verification fiddle returned an empty body"; exit 1; }
case $out in *BSONHEX*) ;; *) echo "ABORT: the SQL insert did not return a bson result"; exit 1;; esac
case $out in *'_id'*) ;; *) echo "ABORT: the mongosh batch did not read the document back"; exit 1;; esac
