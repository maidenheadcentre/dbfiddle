echo 'www-data        ALL=(ALL) NOPASSWD: /mnt/fire/postgres_11/run.sh' >> /etc/sudoers
zfs create tank/fire/postgres_11
cp /mnt/fire/vmlinux-5.10.223 /mnt/fire/postgres_11/vmlinux.bin

<<'EOF' cat > /mnt/fire/postgres_11/config.json
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
    "mem_size_mib": 1024
  }
}
EOF

<<'EOF' cat > /mnt/fire/postgres_11/vsock.c
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
gcc -O2 -static -o /mnt/fire/postgres_11/vsock /mnt/fire/postgres_11/vsock.c

# never write listener.pl here: /mnt/fire/listener.pl is shared by every engine

<<'EOF' cat > /mnt/fire/postgres_11/run.sh
#!/bin/bash
# never pass "$@" through: the sudoers line has no argument spec, so any argument is
# permitted and the caller would be choosing the engine
exec /mnt/fire/run.sh "$(basename "$(dirname "$(readlink -f "$0")")")"
EOF

chmod 700 /mnt/fire/postgres_11/run.sh

mkdir /mnt/fire/postgres_11/mnt

<<'EODOCKER' cat > /mnt/fire/postgres_11/DOCKERFILE
# syntax=docker/dockerfile:1.3-labs
FROM debian:bookworm-slim
RUN apt-get update && apt-get install --no-install-recommends -y tmux wget gnupg ca-certificates systemd-sysv udev haveged
RUN <<'EORUN'
echo "deb https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
apt-get update
apt-get -y install postgresql-11 postgresql-11-postgis-3 postgresql-11-pgrouting postgresql-plpython3-11
<<'EOF' cat > /etc/postgresql/11/main/pg_ident.conf
# MAPNAME     SYSTEM-USERNAME   PG-USERNAME
map           postgres          postgres
map           root              postgres
EOF
<<'EOF' cat > /etc/postgresql/11/main/pg_hba.conf
#TYPE   DATABASE    USER        CIDR-ADDRESS          METHOD
local   all         postgres                          ident map=map
EOF
<<'EOF' cat > /etc/postgresql/11/main/postgresql.conf
data_directory = '/var/lib/postgresql/11/main'
hba_file = '/etc/postgresql/11/main/pg_hba.conf'
ident_file = '/etc/postgresql/11/main/pg_ident.conf'
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

# per-engine tag: concurrent builds on cumbria2 must never share one
DOCKER_BUILDKIT=1 docker build --no-cache -t dummy_postgres_11 - < /mnt/fire/postgres_11/DOCKERFILE
#docker run --rm -ti dummy_postgres_11
dd if=/dev/zero bs=1M count=950 > /mnt/fire/postgres_11/rootfs.ext4
mkfs.ext4 -m 0 /mnt/fire/postgres_11/rootfs.ext4
mount -o loop /mnt/fire/postgres_11/rootfs.ext4 /mnt/fire/postgres_11/mnt
docker run --rm -ti -v /mnt/fire/postgres_11/mnt:/my-rootfs dummy_postgres_11
for d in bin etc home lib lib64 opt root sbin usr dev var; do tar c "/$d" | tar x -C /my-rootfs; done
for dir in run proc sys data; do mkdir /my-rootfs/${dir}; done
exit

# any edit to fiddle.sh or /fiddle invalidates the snapshot: re-run the ceremony
cat <<"EOF" > /mnt/fire/postgres_11/mnt/fiddle.sh
#!/bin/sh
dd if=/dev/random count=1 bs=1
until [ -S /var/run/postgresql/.s.PGSQL.5432 ] ; do sleep 0.1 ; done
until /usr/bin/pg_isready -h localhost -p 5432 >/dev/null 2>&1 ; do sleep 0.05 ; done
echo '["select 1"]' > /tmp/warm.json
echo "warm-up: $(/fiddle /tmp/warm.json /tmp/warm.out >/dev/null 2>&1; cat /tmp/warm.out)" > /dev/console 2>&1
sync
/vsock serve > /data/batches.json
until /usr/bin/pg_isready -h localhost -p 5432 ; do sleep 0.05 ; done
/fiddle
/vsock reply < /data/output.json
reboot -ff
EOF

chmod 700 /mnt/fire/postgres_11/mnt/fiddle.sh

#mount -o loop /mnt/fire/postgres_11/rootfs.ext4 /mnt/fire/postgres_11/mnt
<<'EOC' cat > /mnt/fire/postgres_11/fiddle.c
/* never transcode a non-UTF-8 client_encoding back to UTF-8: a fiddle sees its session's
 * own bytes, and invalid UTF-8 becomes U+FFFD */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

typedef struct { char *s; size_t len; } batch;

static batch *parse_batches(const char *text, size_t *count){
  size_t cap = 8, n = 0;
  batch *v = malloc(cap * sizeof *v);
  if(!v) oom();
  const char *p = skip_ws(text);
  if(*p != '[') goto fail;
  p = skip_ws(p + 1);
  if(*p == ']'){ p++; goto done; }
  for(;;){
    sbuf s = {0};
    sb_reserve(&s, 1);
    s.s[0] = 0;   /* [""] must reach PQsendQuery NUL-terminated, not as raw malloc */
    if(!parse_json_string(&p, &s)){ sb_free(&s); goto fail; }
    if(n == cap){
      cap *= 2;
      v = realloc(v, cap * sizeof *v);
      if(!v) oom();
    }
    v[n].s = s.s;
    v[n].len = s.len;
    n++;
    p = skip_ws(p);
    if(*p == ','){ p = skip_ws(p + 1); continue; }
    if(*p == ']'){ p++; break; }
    goto fail;
  }
done:
  if(*skip_ws(p)) goto fail;
  *count = n;
  return v;
fail:
  for(size_t i = 0; i < n; i++) free(v[i].s);
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
  PQclear(PQexec(conn, "set search_path to public,x_tablefunc,x_pg_trgm,x_intarray,"
                       "x_hstore,x_tsm_system_rows,x_unaccent,x_ltree,x_postgis;"));

  size_t blen = 0, nb = 0;
  char *btext = read_file(inpath, &blen);
  batch *batches = btext ? parse_batches(btext, &nb) : NULL;

  sbuf out = {0};
  sb_putc(&out, '[');
  for(size_t i = 0; i < nb; i++){
    sbuf md = {0};
    if(PQsendQuery(conn, batches[i].s)){
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

cp /mnt/fire/postgres_11/fiddle.c /mnt/fire/postgres_11/mnt/fiddle.c
docker run --rm -v /mnt/fire/postgres_11/mnt:/my-rootfs dummy_postgres_11 -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends gcc libc6-dev libpq-dev && gcc -O2 -Wall -I$(pg_config --includedir) -o /my-rootfs/fiddle /my-rootfs/fiddle.c -lpq && rm /my-rootfs/fiddle.c'
chroot /mnt/fire/postgres_11/mnt /usr/bin/ldd /fiddle
# drop the image: cumbria2's root filesystem fills otherwise
docker rmi dummy_postgres_11

cp /mnt/fire/postgres_11/vsock /mnt/fire/postgres_11/mnt/vsock
chmod 755 /mnt/fire/postgres_11/mnt/vsock

umount /mnt/fire/postgres_11/mnt

# read the headroom after the umount: before it the superblock still shows the empty image
_bs=$(dumpe2fs -h /mnt/fire/postgres_11/rootfs.ext4 2>/dev/null | awk -F: '/^Block size/{print $2+0}')
_fb=$(dumpe2fs -h /mnt/fire/postgres_11/rootfs.ext4 2>/dev/null | awk -F: '/^Free blocks/{print $2+0}')
_free=$(( _bs * _fb / 1048576 ))
echo "rootfs free: ${_free}M"
[ "$_free" -ge 50 ] || { echo "FAIL: only ${_free}M free, raise the dd count= above and rebuild"; exit 1; }

zfs set recordsize=16K tank/fire/postgres_11

cd /mnt/fire/postgres_11
rm -f mem vmstate v.sock* /tmp/fc-snap-postgres_11.sock /tmp/fc-snap-postgres_11.log
firecracker-1.13 --api-sock /tmp/fc-snap-postgres_11.sock --config-file config.json > /tmp/fc-snap-postgres_11.log 2>&1 &
until grep -q FIDDLE-READY /tmp/fc-snap-postgres_11.log ; do sleep 0.1 ; done
sleep 0.3
curl -sf --unix-socket /tmp/fc-snap-postgres_11.sock -X PATCH http://localhost/vm -H 'Content-Type: application/json' -d '{"state":"Paused"}'
curl -sf --unix-socket /tmp/fc-snap-postgres_11.sock -X PUT http://localhost/snapshot/create -H 'Content-Type: application/json' -d '{"snapshot_type":"Full","snapshot_path":"vmstate","mem_file_path":"mem"}'
kill $! || true

# never -R: against a live engine it destroys the clones of in-flight fiddles
zfs destroy tank/fire/postgres_11@base 2>/dev/null || true
zfs snapshot tank/fire/postgres_11@base

out=$(echo '["select 1"]' | /mnt/fire/postgres_11/run.sh) || true
printf '%s\n' "$out"
# run.sh has no meaningful exit status: assert on the body
[ -n "$out" ] || { echo "ABORT: verification fiddle returned an empty body"; exit 1; }
