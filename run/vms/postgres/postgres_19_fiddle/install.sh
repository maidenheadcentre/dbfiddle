echo 'www-data        ALL=(ALL) NOPASSWD: /mnt/fire/postgres_19_fiddle/run.sh' >> /etc/sudoers
zfs create tank/fire/postgres_19_fiddle
cp /mnt/fire/vmlinux-5.10.223 /mnt/fire/postgres_19_fiddle/vmlinux.bin

# 32M is frozen into vmstate as the guest's virtio-blk capacity: never change it without a
# new ceremony. 01:00 host time is Europe/London, like the fiddle DB's current_date, so the
# dump ends at yesterday.
mkdir -p /mnt/fire/fiddlestats
<<'EOF' cat > /mnt/fire/fiddlestats/sync.sh
#!/bin/bash
set -euo pipefail
cd /mnt/fire/fiddlestats
date
rm -rf stage current.img.new
mkdir stage
curl -fsS --compressed https://dbfiddle.uk/dump > stage/daily.csv
mke2fs -q -t ext4 -m 0 -d stage current.img.new 32M
mv current.img.new current.img
wc -l < stage/daily.csv
EOF
chmod 700 /mnt/fire/fiddlestats/sync.sh
echo '0 1 * * * root /mnt/fire/fiddlestats/sync.sh >> /var/log/fiddlestats.log 2>&1' > /etc/cron.d/fiddlestats
/mnt/fire/fiddlestats/sync.sh

<<'EOF' cat > /mnt/fire/postgres_19_fiddle/config.json
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
    },
    {
      "drive_id": "fiddlestats",
      "path_on_host": "fiddlestats/current.img",
      "is_root_device": false,
      "is_read_only": true
    }
  ],
  "vsock": {
    "guest_cid": 3,
    "uds_path": "v.sock"
  },
  "machine-config": {
    "vcpu_count": 1,
    "mem_size_mib": 1024
  }
}
EOF

<<'EOF' cat > /mnt/fire/postgres_19_fiddle/vsock.c
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
gcc -O2 -static -o /mnt/fire/postgres_19_fiddle/vsock /mnt/fire/postgres_19_fiddle/vsock.c

# never write listener.pl here: /mnt/fire/listener.pl is shared by every engine

<<'EOF' cat > /mnt/fire/postgres_19_fiddle/run.sh
#!/bin/bash
# never pass "$@" through: the sudoers line has no argument spec, so any argument is
# permitted and the caller would be choosing the engine
exec /mnt/fire/run.sh "$(basename "$(dirname "$(readlink -f "$0")")")"
EOF

chmod 700 /mnt/fire/postgres_19_fiddle/run.sh

mkdir /mnt/fire/postgres_19_fiddle/mnt

<<'EODOCKER' cat > /mnt/fire/postgres_19_fiddle/DOCKERFILE
# syntax=docker/dockerfile:1.3-labs
FROM debian:trixie-slim
RUN apt-get update && apt-get install --no-install-recommends -y tmux wget ca-certificates systemd-sysv udev haveged
RUN <<'EORUN'
echo "deb https://apt.postgresql.org/pub/repos/apt trixie-pgdg main 19" > /etc/apt/sources.list.d/pgdg.list
wget --quiet -O /etc/apt/trusted.gpg.d/pgdg.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
apt-get update
apt-get -y install postgresql-19 postgresql-19-postgis-3 postgresql-19-pgrouting postgresql-plpython3-19
<<'EOF' cat > /etc/postgresql/19/main/pg_ident.conf
# MAPNAME     SYSTEM-USERNAME   PG-USERNAME
map           postgres          postgres
map           root              postgres
EOF
<<'EOF' cat > /etc/postgresql/19/main/pg_hba.conf
#TYPE   DATABASE    USER        CIDR-ADDRESS          METHOD
local   all         postgres                          ident map=map
EOF
<<'EOF' cat > /etc/postgresql/19/main/postgresql.conf
data_directory = '/var/lib/postgresql/19/main'
hba_file = '/etc/postgresql/19/main/pg_hba.conf'
ident_file = '/etc/postgresql/19/main/pg_ident.conf'
listen_addresses = '*'
datestyle = 'iso, dmy'
timezone = 'UTC'
logging_collector = on
max_wal_senders = 0
wal_level = minimal
fsync = off
full_page_writes = off
max_parallel_workers_per_gather = 4
EOF
EORUN
RUN <<'EORUN'
# postgresql-server-dev-19 is unpacked, not installed: its dependencies pull ~600M of llvm
# and clang for 11M of headers
apt-get update
apt-get -y install --no-install-recommends gcc libc6-dev make
cd /tmp
apt-get download postgresql-server-dev-19
dpkg -x /tmp/postgresql-server-dev-19_*.deb /
rm -f /tmp/*.deb
# with_llvm=no: PGXS would otherwise call clang, which is not here, for every module's .bc
sed -i 's/^\(with_llvm[[:space:]]*=[[:space:]]*\)yes/\1no/' \
  "$(dirname "$(pg_config --pgxs)")/../Makefile.global"
grep -q "^with_llvm[[:space:]]*=[[:space:]]*no" \
  "$(dirname "$(pg_config --pgxs)")/../Makefile.global"
EORUN
RUN <<'EORUN'
set -e
pg_ctlcluster 19 main start
psql -U postgres -v ON_ERROR_STOP=1 <<'EOF'
create extension file_fdw;
create server dump foreign data wrapper file_fdw;
create foreign table daily(engine text, version text, day date, fiddles integer, fiddlesources integer, visits integer, visitsources integer) server dump options (filename '/fiddlestats/daily.csv', format 'csv', header 'true');
EOF
pg_ctlcluster 19 main stop
EORUN
RUN <<'EORUN'
<<'EOF' cat > /etc/systemd/system/fiddle.service
[Unit]
After=postgresql.service
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

DOCKER_BUILDKIT=1 docker build --no-cache -t dummy_postgres_19_fiddle - < /mnt/fire/postgres_19_fiddle/DOCKERFILE
#docker run --rm -ti dummy_postgres_19_fiddle
# re-derive count= from what the gate after the ceremony prints, never from du in the builder container
dd if=/dev/zero bs=1M count=1145 > /mnt/fire/postgres_19_fiddle/rootfs.ext4
mkfs.ext4 -m 0 /mnt/fire/postgres_19_fiddle/rootfs.ext4
mount -o loop /mnt/fire/postgres_19_fiddle/rootfs.ext4 /mnt/fire/postgres_19_fiddle/mnt
docker run --rm -ti -v /mnt/fire/postgres_19_fiddle/mnt:/my-rootfs dummy_postgres_19_fiddle
for d in bin etc home lib lib64 opt root sbin usr dev var; do tar c "/$d" | tar x -C /my-rootfs; done
for dir in run proc sys data fiddlestats; do mkdir /my-rootfs/${dir}; done
exit

# any edit to fiddle.sh or /fiddle invalidates the snapshot: re-run the ceremony
cat <<"EOF" > /mnt/fire/postgres_19_fiddle/mnt/fiddle.sh
#!/bin/sh
dd if=/dev/random count=1 bs=1
until [ -S /var/run/postgresql/.s.PGSQL.5432 ] ; do sleep 0.1 ; done
until /usr/bin/pg_isready -h localhost -p 5432 >/dev/null 2>&1 ; do sleep 0.05 ; done
echo '["select 1"]' > /tmp/warm.json
echo "warm-up: $(/fiddle /tmp/warm.json /tmp/warm.out >/dev/null 2>&1; cat /tmp/warm.out)" > /dev/console 2>&1
sync
/vsock serve > /data/batches.json
# mem holds the boot-time cache of the ceremony's vdb: drop it before mounting this fiddle's.
# Never mount before the snapshot.
blockdev --flushbufs /dev/vdb
mount -o ro /dev/vdb /fiddlestats
until /usr/bin/pg_isready -h localhost -p 5432 ; do sleep 0.05 ; done
/fiddle
/vsock reply < /data/output.json
reboot -ff
EOF

chmod 700 /mnt/fire/postgres_19_fiddle/mnt/fiddle.sh

#mount -o loop /mnt/fire/postgres_19_fiddle/rootfs.ext4 /mnt/fire/postgres_19_fiddle/mnt
<<'EOC' cat > /mnt/fire/postgres_19_fiddle/fiddle.c
/* never transcode a non-UTF-8 client_encoding back to UTF-8: a fiddle sees its session's
 * own bytes, and invalid UTF-8 becomes U+FFFD */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libpq-fe.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

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

/* lang is "" for SQL, never NULL: the web app maps 'sql' to "" and no runner accepts it */
typedef struct { char *s; size_t len; char *lang; } batch;

static batch *parse_payload(const char *text, size_t *count){
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

/* php trim()'s default charlist */
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

/* ---- c and bash batches ---- */

/* the cwd, and where a c batch's source goes, so its #include "x.h" finds a header a bash
   batch wrote there */
#define SRCDIR "/src"

/* must match data_directory in postgresql.conf, above */
#define PGDATA "/var/lib/postgresql/19/main"

#define CAP (4L << 20)

/* forked children only: a SQL batch is bounded by run.sh's timeout alone */
#define LANG_MS 15000

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

static int write_text(const char *path, const char *s, size_t n){
  FILE *f = fopen(path, "wb");
  if(!f) return 0;
  if(n) fwrite(s, 1, n, f);
  return fclose(f) == 0;
}

static int run_child(char *const argv[], sbuf *so, sbuf *se, int *status, long deadline){
  int op[2], ep[2];
  if(pipe(op) < 0 || pipe(ep) < 0) return 0;

  pid_t pid = fork();
  if(pid < 0){ close(op[0]); close(op[1]); close(ep[0]); close(ep[1]); return 0; }
  if(pid == 0){
    /* /dev/null on stdin, or a batch that reads it blocks until the deadline */
    int nul = open("/dev/null", O_RDONLY);
    dup2(nul, 0); dup2(op[1], 1); dup2(ep[1], 2);
    close(op[0]); close(op[1]); close(ep[0]); close(ep[1]);
    if(chdir(SRCDIR) != 0) _exit(126);
    execv(argv[0], argv);
    _exit(127);
  }
  close(op[1]); close(ep[1]);

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
        p[i].fd = -1;
        done++;
      }
    }
  }
  close(op[0]); close(ep[0]);
  int st = 0;
  waitpid(pid, &st, 0);
  *status = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
  return killed;
}

static int fence_child(sbuf *md, char *const argv[], long deadline){
  if(now_ms() >= deadline){
    const char *m = "not run: an earlier batch used the runner's time budget";
    fence_block(md, m, strlen(m), "error");
    return -1;
  }
  sbuf so = {0}, se = {0};
  int status = 0;
  int killed = run_child(argv, &so, &se, &status, deadline);
  if(so.len) fence_plain(md, so.s, so.len, "");
  if(se.len) fence_block(md, se.s, se.len, "error");
  if(killed){
    const char *m = "batch did not finish within the runner's time budget";
    fence_block(md, m, strlen(m), "error");
    status = -1;
  } else if(status != 0 && !se.len){
    char m[64];
    int n = snprintf(m, sizeof m, "exited with status %d", status);
    fence_block(md, m, (size_t)n, "error");
  }
  sb_free(&so);
  sb_free(&se);
  return status;
}

/* one module path per c batch, numbered among c batches only: postgres matches a loaded
   module by path and never restats it, so a reused path would silently keep the old code */
static void run_lang(sbuf *md, const char *lang, const batch *b, size_t i,
                     size_t *cn, long deadline){
  char path[64];

  if(!strcmp(lang, "c")){
    char srcname[32], mod[32], cmd[512];
    (*cn)++;
    snprintf(srcname, sizeof srcname, "fiddle.%zu.c", *cn);
    snprintf(mod, sizeof mod, "fiddle.%zu.so", *cn);
    snprintf(path, sizeof path, SRCDIR "/%s", srcname);
    if(!write_text(path, b->s, b->len)){
      const char *m = "could not write the source file";
      fence_block(md, m, strlen(m), "error");
      return;
    }
    snprintf(cmd, sizeof cmd,
             "gcc -I\"$(pg_config --includedir-server)\" -fPIC -shared "
             "-o \"$(pg_config --pkglibdir)/%s\" %s", mod, srcname);
    char *argv[] = { "/bin/sh", "-c", cmd, NULL };
    if(fence_child(md, argv, deadline) == 0){
      char m[64];
      int n = snprintf(m, sizeof m, "built %s", mod);
      fence_block(md, m, (size_t)n, "status");
    }
    return;
  }

  if(!strcmp(lang, "bash")){
    /* named for its batch, so bash's own "batch3.sh: line 2" says which one failed */
    snprintf(path, sizeof path, SRCDIR "/batch%zu.sh", i + 1);
    if(!write_text(path, b->s, b->len)){
      const char *m = "could not write the script";
      fence_block(md, m, strlen(m), "error");
      return;
    }
    char *argv[] = { "/bin/bash", path, NULL };
    fence_child(md, argv, deadline);
    return;
  }

  sbuf m = {0};
  sb_puts(&m, "unknown language: ");
  sb_puts(&m, lang);
  fence_block(md, m.s, m.len, "error");
  sb_free(&m);
}

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

/* never cache this: the clock jump at restore can rotate the log mid-fiddle */
static char *current_logfile(void){
  size_t n = 0;
  char *t = read_file(PGDATA "/current_logfiles", &n);
  if(!t) return NULL;
  char *out = NULL;
  for(char *p = t; *p; ){
    char *eol = strchr(p, '\n');
    if(eol) *eol = 0;
    if(!strncmp(p, "stderr ", 7)){
      const char *rel = p + 7;
      out = malloc(sizeof PGDATA + strlen(rel) + 1);
      if(!out) oom();
      if(*rel == '/') strcpy(out, rel);
      else sprintf(out, "%s/%s", PGDATA, rel);
      break;
    }
    if(!eol) break;
    p = eol + 1;
  }
  free(t);
  return out;
}

static int line_has(const char *p, size_t len, const char *needle){
  size_t nl = strlen(needle);
  for(size_t i = 0; nl <= len && i <= len - nl; i++)
    if(!memcmp(p + i, needle, nl)) return 1;
  return 0;
}

/* libpq sees the socket close before postgres has reaped the child and logged why, so
   this waits for the line rather than reading once. */
static void append_crash_log(sbuf *md, const char *path0, long off0){
  for(int t = 0; t < 20; t++){
    char *path = current_logfile();
    if(path){
      long off = (path0 && !strcmp(path, path0)) ? off0 : 0;
      size_t n = 0;
      char *text = read_file(path, &n);
      free(path);
      if(text){
        sbuf hit = {0};
        for(char *p = text + ((size_t)off < n ? (size_t)off : n); *p; ){
          char *eol = strchr(p, '\n');
          size_t len = eol ? (size_t)(eol - p) : strlen(p);
          if(line_has(p, len, "was terminated by signal") ||
             line_has(p, len, "exited with exit code")){
            if(hit.len) sb_putc(&hit, '\n');
            sb_putn(&hit, p, len);
          }
          if(!eol) break;
          p = eol + 1;
        }
        free(text);
        if(hit.len){
          fence_block(md, hit.s, hit.len, "error");
          sb_free(&hit);
          return;
        }
        sb_free(&hit);
      }
    }
    poll(NULL, 0, 50);
  }
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
  PQclear(PQexec(conn, "set search_path to public,x_tablefunc,x_pg_trgm,x_intarray,"
                       "x_hstore,x_tsm_system_rows,x_unaccent,x_ltree,x_postgis;"));

  mkdir(SRCDIR, 0700);
  long deadline = now_ms() + LANG_MS;

  char *logpath = current_logfile();
  long logoff = 0;
  if(logpath){
    struct stat st;
    if(stat(logpath, &st) == 0) logoff = (long)st.st_size;
  }

  size_t blen = 0, nb = 0;
  char *btext = read_file(inpath, &blen);
  batch *batches = btext ? parse_payload(btext, &nb) : NULL;

  sbuf out = {0};
  sb_putc(&out, '[');
  int crashed = 0;
  size_t cn = 0;
  for(size_t i = 0; i < nb; i++){
    sbuf md = {0};
    const char *lang = batches[i].lang;

    if(crashed){
      /* the backend is gone; this batch never ran, and says so by saying nothing */
    } else if(lang[0]){
      run_lang(&md, lang, &batches[i], i, &cn, deadline);
    } else if(PQsendQuery(conn, batches[i].s)){
      PGresult *res;
      /* drain to NULL always: a half-read batch would desync the next one */
      while((res = PQgetResult(conn))){
        const char *e = PQresultErrorMessage(res);
        if(e && *e){
          /* fence_block already ends in two newlines; only a fence-less result needs the second */
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

    /* the connection, not the result: an ordinary SQL error is PGRES_FATAL_ERROR too.
       Never reconnect: the session's state went with the backend. */
    if(!crashed && PQstatus(conn) != CONNECTION_OK){
      crashed = 1;
      append_crash_log(&md, logpath, logoff);
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

cp /mnt/fire/postgres_19_fiddle/fiddle.c /mnt/fire/postgres_19_fiddle/mnt/fiddle.c
docker run --rm -v /mnt/fire/postgres_19_fiddle/mnt:/my-rootfs dummy_postgres_19_fiddle -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends gcc libc6-dev libpq-dev && gcc -O2 -Wall -I$(pg_config --includedir) -o /my-rootfs/fiddle /my-rootfs/fiddle.c -lpq && rm /my-rootfs/fiddle.c'
chroot /mnt/fire/postgres_19_fiddle/mnt /usr/bin/ldd /fiddle

cp /mnt/fire/postgres_19_fiddle/vsock /mnt/fire/postgres_19_fiddle/mnt/vsock
chmod 755 /mnt/fire/postgres_19_fiddle/mnt/vsock

umount /mnt/fire/postgres_19_fiddle/mnt

zfs set recordsize=16K tank/fire/postgres_19_fiddle

mkdir -p /mnt/fire/postgres_19_fiddle/fiddlestats
cp /mnt/fire/fiddlestats/current.img /mnt/fire/postgres_19_fiddle/fiddlestats/
cd /mnt/fire/postgres_19_fiddle
rm -f mem vmstate v.sock* /tmp/fc-snap-postgres_19_fiddle.sock /tmp/fc-snap-postgres_19_fiddle.log
firecracker-1.13 --api-sock /tmp/fc-snap-postgres_19_fiddle.sock --config-file config.json > /tmp/fc-snap-postgres_19_fiddle.log 2>&1 &
until grep -q FIDDLE-READY /tmp/fc-snap-postgres_19_fiddle.log ; do sleep 0.1 ; done
sleep 0.3
curl -sf --unix-socket /tmp/fc-snap-postgres_19_fiddle.sock -X PATCH http://localhost/vm -H 'Content-Type: application/json' -d '{"state":"Paused"}'
curl -sf --unix-socket /tmp/fc-snap-postgres_19_fiddle.sock -X PUT http://localhost/snapshot/create -H 'Content-Type: application/json' -d '{"snapshot_type":"Full","snapshot_path":"vmstate","mem_file_path":"mem"}'
kill $! || true
rm /mnt/fire/postgres_19_fiddle/fiddlestats/current.img

# never -R: against a live engine it destroys the clones of in-flight fiddles
zfs destroy tank/fire/postgres_19_fiddle@base 2>/dev/null || true
zfs snapshot tank/fire/postgres_19_fiddle@base

gate=$(mktemp -d)
if ! mount -o loop,ro,norecovery /mnt/fire/postgres_19_fiddle/rootfs.ext4 "$gate"; then
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

out=$(echo '["select 1"]' | /mnt/fire/postgres_19_fiddle/run.sh) || true
printf '%s\n' "$out"
# run.sh has no meaningful exit status: assert on the body
[ -n "$out" ] || { echo "ABORT: verification fiddle returned an empty body"; exit 1; }

out=$(echo '["select max(day) from daily"]' | /mnt/fire/postgres_19_fiddle/run.sh) || true
printf '%s\n' "$out"
case $out in *"| $(date -d yesterday +%F) |"*) ;;
  *) echo "ABORT: daily did not read yesterday from the fiddlestats drive"; exit 1 ;;
esac

cat > /tmp/postgres_19_fiddle-langcheck.json <<'EOF'
[["#include \"postgres.h\"\n#include \"fmgr.h\"\n#include \"varatt.h\"\nPG_MODULE_MAGIC;\nPG_FUNCTION_INFO_V1(fiddle_answer);\nDatum fiddle_answer(PG_FUNCTION_ARGS){ PG_RETURN_INT32(42); }","c"],
 ["create function fiddle_answer() returns int as 'fiddle.1', 'fiddle_answer' language c strict;",""],
 ["select fiddle_answer() as c_sees;",""],
 ["cat > Makefile <<'MK'\nMODULES = gate\nPG_CONFIG = pg_config\nPGXS := $(shell $(PG_CONFIG) --pgxs)\ninclude $(PGXS)\nMK\ncp fiddle.1.c gate.c\nmake -s && echo bash-built:$(ls gate.so)","bash"]]
EOF
lang=$(/mnt/fire/postgres_19_fiddle/run.sh < /tmp/postgres_19_fiddle-langcheck.json) || true
printf '%s\n' "$lang"
case $lang in *"built fiddle.1.so"*) ;;
  *) echo "ABORT: the c batch did not report a built module"; exit 1 ;;
esac
case $lang in *"| 42 |"*) ;;
  *) echo "ABORT: the compiled C function did not return through SQL"; exit 1 ;;
esac
case $lang in *bash-built:gate.so*) ;;
  *) echo "ABORT: the bash batch did not build a module through PGXS make"; exit 1 ;;
esac

cat > /tmp/postgres_19_fiddle-crashcheck.json <<'EOF'
["select 1 as before","copy (select 1) to program 'kill -SEGV $PPID'","select 2 as after"]
EOF
crash=$(/mnt/fire/postgres_19_fiddle/run.sh < /tmp/postgres_19_fiddle-crashcheck.json) || true
printf '%s\n' "$crash"
case $crash in *"was terminated by signal"*) ;;
  *) echo "ABORT: a backend crash was not annotated from the postgres log"; exit 1 ;;
esac
