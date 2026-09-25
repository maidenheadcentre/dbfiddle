echo 'www-data        ALL=(ALL) NOPASSWD: /mnt/fire/sqlite_3.27/run.sh' >> /etc/sudoers
zfs create tank/fire/sqlite_3.27
cp /mnt/fire/vmlinux-5.10.223 /mnt/fire/sqlite_3.27/vmlinux.bin

<<'EOF' cat > /mnt/fire/sqlite_3.27/config.json
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

<<'EOF' cat > /mnt/fire/sqlite_3.27/vsock.c
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
gcc -O2 -static -o /mnt/fire/sqlite_3.27/vsock /mnt/fire/sqlite_3.27/vsock.c

# never write listener.pl here: /mnt/fire/listener.pl is shared by every engine

<<'EOF' cat > /mnt/fire/sqlite_3.27/run.sh
#!/bin/bash
# never pass "$@" through: the sudoers line has no argument spec, so any argument is
# permitted and the caller would be choosing the engine
exec /mnt/fire/run.sh "$(basename "$(dirname "$(readlink -f "$0")")")"
EOF

chmod 700 /mnt/fire/sqlite_3.27/run.sh

mkdir /mnt/fire/sqlite_3.27/mnt

<<'EODOCKER' cat > /mnt/fire/sqlite_3.27/DOCKERFILE
FROM debian:trixie-slim
RUN apt-get update && apt-get install --no-install-recommends -y systemd-sysv udev haveged
RUN echo '[Service]' > /etc/systemd/system/fiddle.service \
  && echo 'ExecStart=/fiddle.sh' >> /etc/systemd/system/fiddle.service \
  && echo '[Install]' >> /etc/systemd/system/fiddle.service \
  && echo 'WantedBy=default.target' >> /etc/systemd/system/fiddle.service \
  && systemctl enable fiddle
RUN echo "root:Docker!" | chpasswd
ENTRYPOINT ["bash"]
EODOCKER

# ---- the fiddle runner ----
# fiddle.c is shared across the sqlite family apart from sqlite_3.27's heap limit and
# sqlite_3.53's language batches: carry a change to every copy.
# row counts are sqlite3_total_changes() deltas, never sqlite3_changes(), which after a
# CREATE TABLE still reports the previous statement's count
<<'EOC' cat > /mnt/fire/sqlite_3.27/fiddle.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sqlite3.h"

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
    s.s[0] = 0;   /* [""] must reach sqlite3_prepare_v2 NUL-terminated */
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
    } else if(c < 0x80){
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
  int line_start = 1;
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

/* ---- sqlite ---- */

static int step_and_render(sqlite3_stmt *st, sbuf *md){
  int nf = sqlite3_column_count(st);
  int rc;
  if(nf == 0){
    while((rc = sqlite3_step(st)) == SQLITE_ROW) ;
    return rc;
  }

  int *numeric = malloc((size_t)nf * sizeof *numeric);
  int *anyval = calloc((size_t)nf, sizeof *anyval);
  if(!numeric || !anyval) oom();
  for(int i = 0; i < nf; i++) numeric[i] = 1;

  sbuf rows = {0};
  int nrows = 0;
  while((rc = sqlite3_step(st)) == SQLITE_ROW){
    nrows++;
    sb_puts(&rows, "|");
    for(int i = 0; i < nf; i++){
      int t = sqlite3_column_type(st, i);
      sb_putc(&rows, ' ');
      if(t == SQLITE_NULL) sb_puts(&rows, "*null*");
      else {
        anyval[i] = 1;
        if(t != SQLITE_INTEGER && t != SQLITE_FLOAT) numeric[i] = 0;
        if(t == SQLITE_BLOB){
          const unsigned char *b = sqlite3_column_blob(st, i);
          int n = sqlite3_column_bytes(st, i);
          sb_putc(&rows, '`');
          for(int k = 0; k < n; k++){
            char h[3];
            snprintf(h, sizeof h, "%02x", b[k]);
            sb_putn(&rows, h, 2);
          }
          sb_putc(&rows, '`');
        } else {
          /* _text before _bytes: the length must describe the text conversion */
          const unsigned char *v = sqlite3_column_text(st, i);
          int n = sqlite3_column_bytes(st, i);
          md_cell(&rows, v ? (const char *)v : "", (size_t)(v ? n : 0));
        }
      }
      sb_puts(&rows, " |");
    }
    sb_putc(&rows, '\n');
  }

  if(rc != SQLITE_DONE && !nrows){
    sb_free(&rows);
    free(numeric);
    free(anyval);
    return rc;
  }

  sbuf h2 = {0};
  sb_puts(md, "|");
  sb_puts(&h2, "|");
  for(int i = 0; i < nf; i++){
    const char *name = sqlite3_column_name(st, i);
    if(!name) name = "";
    size_t nl = strlen(name);
    int ar = anyval[i] && numeric[i];
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
  if(rows.len) sb_putn(md, rows.s, rows.len);
  sb_free(&rows);
  free(numeric);
  free(anyval);
  return rc;
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

int main(int argc, char **argv){
  const char *inpath = argc > 1 ? argv[1] : "/tmp/batches.json";
  const char *outpath = argc > 2 ? argv[2] : "/tmp/output.json";

  sqlite3 *db = NULL;
  if(sqlite3_open(":memory:", &db) != SQLITE_OK){
    fputs("could not open the database\n", stderr);
    return 1;
  }
  /* the heap limit is -DSQLITE_MAX_MEMORY in the build: hard_heap_limit64() is 3.31+,
     and soft_heap_limit64() only trims the cache, never failing an allocation */

  size_t blen = 0, nb = 0;
  char *btext = read_file(inpath, &blen);
  batch *batches = btext ? parse_batches(btext, &nb) : NULL;

  sbuf out = {0};
  sb_putc(&out, '[');
  for(size_t i = 0; i < nb; i++){
    sbuf md = {0};
    const char *tail = batches[i].s;
    while(tail && *tail){
      sqlite3_stmt *st = NULL;
      const char *next = NULL;
      int rc = sqlite3_prepare_v2(db, tail, -1, &st, &next);
      if(rc != SQLITE_OK){
        const char *e = sqlite3_errmsg(db);
        fence_block(&md, e, strlen(e), "error");
        break;
      }
      if(!st){
        if(next == tail) break;   /* no progress: never spin */
        tail = next;
        continue;
      }
      int before = sqlite3_total_changes(db);
      rc = step_and_render(st, &md);
      int changed = sqlite3_total_changes(db) - before;
      sqlite3_finalize(st);
      if(rc != SQLITE_DONE){
        const char *e = sqlite3_errmsg(db);
        fence_block(&md, e, strlen(e), "error");
        break;
      }
      if(changed){
        char tag[64];
        int n = snprintf(tag, sizeof tag, "%d row%s affected",
                         changed, changed == 1 ? "" : "s");
        fence_block(&md, tag, (size_t)n, "status");
      } else {
        sb_putc(&md, '\n');
      }
      tail = next;
    }
    if(i) sb_putc(&out, ',');
    json_emit_string(&out, md.s ? md.s : "", md.len);
    sb_free(&md);
  }
  sb_putc(&out, ']');
  sqlite3_close(db);

  FILE *f = fopen(outpath, "wb");
  if(!f) return 1;
  fwrite(out.s, 1, out.len, f);
  fclose(f);
  return 0;
}
EOC

# ---- the sqlite amalgamation ----
mkdir -p /mnt/fire/sqlite_3.27/src
curl -sfLo /mnt/fire/sqlite_3.27/src/sqlite-amalgamation-3270200.zip \
     https://www.sqlite.org/2019/sqlite-amalgamation-3270200.zip
<<'EOF' sha256sum -c -
00fc566f1cece7f4264dc93a7151c64bb794e58c5d20ea65f46b9f7cb36bc34b  /mnt/fire/sqlite_3.27/src/sqlite-amalgamation-3270200.zip
EOF
unzip -o -j -d /mnt/fire/sqlite_3.27/src \
      /mnt/fire/sqlite_3.27/src/sqlite-amalgamation-3270200.zip
grep -m1 'define SQLITE_VERSION ' /mnt/fire/sqlite_3.27/src/sqlite3.h

# per-engine tag: concurrent builds on cumbria2 must never share one
DOCKER_BUILDKIT=1 docker build --no-cache -t dummy_sqlite_3.27 - < /mnt/fire/sqlite_3.27/DOCKERFILE
# 240M: a 143M tree plus /fiddle and /vsock leaves 89M free
dd if=/dev/zero bs=1M count=240 > /mnt/fire/sqlite_3.27/rootfs.ext4
mkfs.ext4 -m 0 /mnt/fire/sqlite_3.27/rootfs.ext4
mount -o loop /mnt/fire/sqlite_3.27/rootfs.ext4 /mnt/fire/sqlite_3.27/mnt
docker run --rm -ti -v /mnt/fire/sqlite_3.27/mnt:/my-rootfs dummy_sqlite_3.27
for d in bin etc home lib lib64 opt root sbin usr dev var; do tar c "/$d" | tar x -C /my-rootfs; done
for dir in run proc sys; do mkdir /my-rootfs/${dir}; done
mknod -m 666 /my-rootfs/dev/ttyS0 c 4 64
exit

# no SQLITE_DQS=0, ENABLE_BYTECODE_VTAB or ENABLE_MATH_FUNCTIONS: they postdate 3.27 and
# would compile silently to nothing, so double-quoted strings stay on
# ENABLE_JSON1: json is not built in by default before 3.38
# SQLITE_MAX_MEMORY=629145600 is 600M, below the 1024MiB guest: an oversized query gets
# an SQL error rather than the OOM killer and an empty body
# never add SQLITE_DEFAULT_MEMSTATUS=0: the limit rides on the allocation accounting it
# turns off, and would silently do nothing
cp /mnt/fire/sqlite_3.27/fiddle.c /mnt/fire/sqlite_3.27/mnt/fiddle.c
cp /mnt/fire/sqlite_3.27/src/sqlite3.c /mnt/fire/sqlite_3.27/src/sqlite3.h /mnt/fire/sqlite_3.27/mnt/
docker run --rm -v /mnt/fire/sqlite_3.27/mnt:/my-rootfs debian:trixie-slim bash -c '
  apt-get update -qq && apt-get install -y -qq --no-install-recommends gcc libc6-dev
  gcc -O2 -Wall -I/my-rootfs -o /my-rootfs/fiddle /my-rootfs/fiddle.c /my-rootfs/sqlite3.c \
      -DSQLITE_THREADSAFE=0 \
      -DSQLITE_ENABLE_JSON1 \
      -DSQLITE_MAX_MEMORY=629145600 \
      -DSQLITE_ENABLE_FTS4 \
      -DSQLITE_ENABLE_FTS5 \
      -DSQLITE_ENABLE_RTREE \
      -DSQLITE_ENABLE_GEOPOLY \
      -DSQLITE_ENABLE_DBSTAT_VTAB \
      -DSQLITE_ENABLE_STMTVTAB \
      -DSQLITE_ENABLE_OFFSET_SQL_FUNC \
      -DSQLITE_ENABLE_EXPLAIN_COMMENTS \
      -DSQLITE_USE_ALLOCA \
      -lm -ldl
  rm /my-rootfs/fiddle.c /my-rootfs/sqlite3.c /my-rootfs/sqlite3.h'
chroot /mnt/fire/sqlite_3.27/mnt /usr/bin/ldd /fiddle

docker rmi dummy_sqlite_3.27

cp /mnt/fire/sqlite_3.27/vsock /mnt/fire/sqlite_3.27/mnt/vsock
chmod 755 /mnt/fire/sqlite_3.27/mnt/vsock

# any edit to fiddle.sh or /fiddle invalidates the snapshot: re-run the ceremony
cat <<"EOF" > /mnt/fire/sqlite_3.27/mnt/fiddle.sh
#!/bin/sh
dd if=/dev/random count=1 bs=1
echo '["select 1"]' > /tmp/warm.json
echo "warm-up: $(/fiddle /tmp/warm.json /tmp/warmout.json >/dev/null 2>&1; cat /tmp/warmout.json)" > /dev/console 2>&1
sync
/vsock serve > /tmp/batches.json
/fiddle
/vsock reply < /tmp/output.json
reboot -ff
EOF

chmod 700 /mnt/fire/sqlite_3.27/mnt/fiddle.sh

umount /mnt/fire/sqlite_3.27/mnt

# read the headroom after the umount: before it the superblock still shows the empty image
dumpe2fs -h /mnt/fire/sqlite_3.27/rootfs.ext4 2>/dev/null | grep -E 'Block (count|size)|Free blocks'
blk=$(dumpe2fs -h /mnt/fire/sqlite_3.27/rootfs.ext4 2>/dev/null | awk '/^Block size:/{print $3}')
free_mb=$(( $(dumpe2fs -h /mnt/fire/sqlite_3.27/rootfs.ext4 2>/dev/null | awk '/^Free blocks:/{print $3}') * blk / 1048576 ))
echo "rootfs free: ${free_mb}M (target 50-100M)"
[ "$free_mb" -ge 50 ] || { echo "FAIL: rootfs headroom ${free_mb}M below the 50M floor - raise dd count"; exit 1; }

zfs set recordsize=16K tank/fire/sqlite_3.27

cd /mnt/fire/sqlite_3.27
rm -f mem vmstate v.sock* /tmp/fc-snap-sqlite_3.27.sock /tmp/fc-snap-sqlite_3.27.log
firecracker-1.13 --api-sock /tmp/fc-snap-sqlite_3.27.sock --config-file config.json > /tmp/fc-snap-sqlite_3.27.log 2>&1 &
until grep -q FIDDLE-READY /tmp/fc-snap-sqlite_3.27.log ; do sleep 0.1 ; done
# proves the warm-up ran: a runner that failed to compile shows up nowhere else
grep -a 'warm-up:' /tmp/fc-snap-sqlite_3.27.log
sleep 0.3
curl -sf --unix-socket /tmp/fc-snap-sqlite_3.27.sock -X PATCH http://localhost/vm -H 'Content-Type: application/json' -d '{"state":"Paused"}'
curl -sf --unix-socket /tmp/fc-snap-sqlite_3.27.sock -X PUT http://localhost/snapshot/create -H 'Content-Type: application/json' -d '{"snapshot_type":"Full","snapshot_path":"vmstate","mem_file_path":"mem"}'
kill $! || true

# never -R: against a live engine it destroys the clones of in-flight fiddles
zfs destroy tank/fire/sqlite_3.27@base 2>/dev/null || true
zfs snapshot tank/fire/sqlite_3.27@base

out=$(echo '["select sqlite_version()"]' | /mnt/fire/sqlite_3.27/run.sh) || true
printf '%s\n' "$out"
# run.sh has no meaningful exit status: assert on the body
[ -n "$out" ] || { echo "ABORT: verification fiddle returned an empty body"; exit 1; }
