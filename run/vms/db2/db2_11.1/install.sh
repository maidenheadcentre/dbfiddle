echo 'www-data        ALL=(ALL) NOPASSWD: /mnt/fire/db2_11.1/run.sh' >> /etc/sudoers
zfs create tank/fire/db2_11.1
cp /mnt/fire/vmlinux-6.1.141 /mnt/fire/db2_11.1/vmlinux.bin

# no-kvmapf: a task asleep on an async page fault at snapshot time never wakes after restore
<<'EOF' cat > /mnt/fire/db2_11.1/config.json
{
  "boot-source": {
    "kernel_image_path": "vmlinux.bin",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off random.trust_cpu=on no-kvmapf"
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
    "vcpu_count": 2,
    "mem_size_mib": 4096
  }
}
EOF

<<'EOF' cat > /mnt/fire/db2_11.1/vsock.c
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
gcc -O2 -static -o /mnt/fire/db2_11.1/vsock /mnt/fire/db2_11.1/vsock.c

# never write listener.pl here: /mnt/fire/listener.pl is shared by every engine

<<'EOF' cat > /mnt/fire/db2_11.1/run.sh
#!/bin/bash
# never pass "$@" through: the sudoers line has no argument spec, so any argument is
# permitted and the caller would be choosing the engine
exec /mnt/fire/run.sh "$(basename "$(dirname "$(readlink -f "$0")")")"
EOF
chmod 755 /mnt/fire/db2_11.1/run.sh

# gcc stays: the runner is compiled in a chroot of this rootfs further down. The i686
# packages, binutils and numactl-libs are for db2prereqcheck.
cat > /mnt/fire/db2_11.1/DOCKERFILE <<"EOF"
FROM oraclelinux:8
RUN dnf -y install libaio ksh perl-interpreter perl-Sys-Syslog binutils file \
      numactl-libs pam glibc.i686 pam.i686 libstdc++ libstdc++.i686 libaio.i686 \
      net-tools hostname procps-ng util-linux findutils tar gawk sed which systemd gcc
RUN echo '[Service]' > /etc/systemd/system/fiddle.service \
  && echo 'ExecStart=/fiddle.sh' >> /etc/systemd/system/fiddle.service \
  && echo '[Install]' >> /etc/systemd/system/fiddle.service \
  && echo 'WantedBy=default.target' >> /etc/systemd/system/fiddle.service \
  && systemctl enable fiddle
RUN systemctl disable getty@tty1.service \
  && echo ttyS0 > /etc/securetty \
  && echo '[Service]' > /etc/systemd/system/mygetty.service \
  && echo 'ExecStart=/usr/sbin/agetty -a root -L 9600 ttyS0 vt102' >> /etc/systemd/system/mygetty.service \
  && echo '[Install]' >> /etc/systemd/system/mygetty.service \
  && echo 'WantedBy=default.target' >> /etc/systemd/system/mygetty.service \
  && systemctl enable mygetty
RUN dnf clean all
RUN echo "root:Docker!" | chpasswd
ENTRYPOINT ["bash"]
EOF

# AUTOSTART and START_DURING_INSTALL stay NO: an instance racing fiddle.sh breaks the ceremony
<<'EOF' cat > /mnt/fire/db2_11.1/db2.rsp
PROD                           = DB2_SERVER_EDITION
FILE                           = /opt/ibm/db2/V11.1
LIC_AGREEMENT                  = ACCEPT
INSTALL_TYPE                   = CUSTOM
COMP                           = APPLICATION_DEVELOPMENT_TOOLS
INSTALL_TSAMP                  = NO
INSTANCE                       = DB2_INST
DB2_INST.NAME                  = db2inst
DB2_INST.TYPE                  = ESE
DB2_INST.PASSWORD              = hzLedNRWXk3e
DB2_INST.UID                   = 5000
DB2_INST.GID                   = 5000
DB2_INST.GROUP_NAME            = db2inst
DB2_INST.HOME_DIRECTORY        = /home/db2inst
DB2_INST.SVCENAME              = db2c_db2inst
DB2_INST.PORT_NUMBER           = 50000
DB2_INST.FCM_PORT_NUMBER       = 60000
DB2_INST.MAX_LOGICAL_NODES     = 1
DB2_INST.AUTOSTART             = NO
DB2_INST.START_DURING_INSTALL  = NO
DB2_INST.FENCED_USERNAME       = db2sdfe
DB2_INST.FENCED_PASSWORD       = aFjkk2nHZ6WP
DB2_INST.FENCED_UID            = 5001
DB2_INST.FENCED_GID            = 5001
DB2_INST.FENCED_GROUP_NAME     = db2sdfe
DB2_INST.FENCED_HOME_DIRECTORY = /home/db2fsdm
DB2_INST.CONFIGURE_TEXT_SEARCH = NO
EOF

# the media has no download source: a hand-fetched copy must match this digest
echo '937d08247f38cfaea32014972a54e16928a3abcebe58460663049bb123a58694  /iso/db2.111.iso' | sha256sum -c -
mkdir -p /mnt/db2xc111
mountpoint -q /mnt/db2xc111 || mount -o loop,ro /iso/db2.111.iso /mnt/db2xc111

# per-engine tag: concurrent builds on cumbria2 must never share one
mkdir -p /mnt/fire/db2_11.1/ctx
DOCKER_BUILDKIT=1 docker build --no-cache -t dummy_db2_11.1 -f /mnt/fire/db2_11.1/DOCKERFILE /mnt/fire/db2_11.1/ctx

# 2300M leaves 50-100M free after the ~2.2G install
dd if=/dev/zero bs=1M count=2300 > /mnt/fire/db2_11.1/rootfs.ext4
mkfs.ext4 -m 0 /mnt/fire/db2_11.1/rootfs.ext4
mkdir -p /mnt/fire/db2_11.1/mnt
mount -o loop /mnt/fire/db2_11.1/rootfs.ext4 /mnt/fire/db2_11.1/mnt

# --hostname must match the guest's, since db2nodes.cfg records it. db2start needs IPC_OWNER.
docker run --rm -ti --hostname fiddle --shm-size 2g --cap-add=IPC_OWNER \
  -v /mnt/db2xc111:/media:ro -v /mnt/fire/db2_11.1:/ctx:ro \
  -v /mnt/fire/db2_11.1/mnt:/my-rootfs dummy_db2_11.1
# -l must not be /tmp/db2setup.log: db2setup links that path to -l's and dies with DBI1503E.
# rc=1 ("a minor error occurred") is normal on el8, so the install tree is the test.
mkdir -p /tmp/db2log
/media/db2setup -r /ctx/db2.rsp -l /tmp/db2log/setup.log
[ -d /opt/ibm/db2/V11.1 ] || { echo "FAIL: no install tree"; tail -40 /tmp/db2log/setup.log; exit 1; }
runuser -u db2inst -- /bin/bash -lc '
set -e
. /home/db2inst/sqllib/db2profile
db2level
# SPM_NAME defaults to the hostname, which collides with the database name (SQL0901N)
db2 update dbm cfg using spm_name db2spm
db2start
# codeset pinned: a different container default would silently change string results
db2 "create database fiddle using codeset UTF-8 territory US"
db2 connect to fiddle
db2 terminate
db2stop force'
for d in bin etc home lib lib64 opt root sbin usr dev run var; do tar c "/$d" | tar x -C /my-rootfs; done
for dir in proc sys data; do mkdir -p /my-rootfs/${dir}; done
mknod -m 666 /my-rootfs/dev/ttyS0 c 4 64
exit

# replace docker's bind-mounted network identity with the guest's offline one
printf '127.0.0.1 localhost fiddle\n::1 localhost\n' > /mnt/fire/db2_11.1/mnt/etc/hosts
echo fiddle > /mnt/fire/db2_11.1/mnt/etc/hostname

# any edit to fiddle.sh or /fiddle invalidates the snapshot: re-run the ceremony
<<'EOF' cat > /mnt/fire/db2_11.1/mnt/fiddle.sh
#!/bin/sh
dd if=/dev/random count=1 bs=1
runuser -u db2inst -- /bin/bash -lc '. /home/db2inst/sqllib/db2profile; db2start' > /dev/console 2>&1
echo DB2-STARTED > /dev/console
until runuser -u db2inst -- /bin/bash -lc '. /home/db2inst/sqllib/db2profile; db2 connect to fiddle' >/dev/null 2>&1 ; do sleep 0.5 ; done
echo DB2-CONNECTABLE > /dev/console
# DB2CODEPAGE=1208: without it XML carries an ISO-8859-1 declaration over UTF-8 bytes
runuser -u db2inst -- env DB2INSTANCE=db2inst DB2CODEPAGE=1208 /fiddle --warmup > /dev/console 2>&1
echo FIDDLE-WARMED > /dev/console
sync
/vsock serve > /tmp/batches.json
chmod 644 /tmp/batches.json
runuser -u db2inst -- env DB2INSTANCE=db2inst DB2CODEPAGE=1208 /fiddle
/vsock reply < /tmp/output.json
reboot -ff
EOF
chmod 700 /mnt/fire/db2_11.1/mnt/fiddle.sh

<<'EOC' cat > /mnt/fire/db2_11.1/mnt/fiddle.c
/* shared across the db2 family: carry a change to every copy */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sqlcli1.h>

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
    s.s[0] = 0;   /* [""] must reach the CLI NUL-terminated, not as raw malloc */
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
    else if(c == '/'){ sb_puts(out, "\\/"); i++; }   /* php-faithful */
    else if(c < 0x80){
      sb_putc(out, (char)c);
      i++;
    } else {
      /* php-faithful */
      int len = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC2 ? 2 : 0;
      int ok = len && i + (size_t)len <= n;
      for(int k = 1; ok && k < len; k++)
        ok = ((unsigned char)s[i + k] & 0xC0) == 0x80;
      unsigned cp = 0xFFFD;
      if(ok){
        cp = len == 2 ? (c & 0x1Fu) : len == 3 ? (c & 0x0Fu) : (c & 0x07u);
        for(int k = 1; k < len; k++)
          cp = (cp << 6) | ((unsigned char)s[i + k] & 0x3Fu);
        i += (size_t)len;
      } else i++;
      char t[16];
      if(cp >= 0x10000){
        unsigned v = cp - 0x10000;
        snprintf(t, sizeof t, "\\u%04x\\u%04x",
                 0xD800u + (v >> 10), 0xDC00u + (v & 0x3FFu));
      } else snprintf(t, sizeof t, "\\u%04x", cp);
      sb_puts(out, t);
    }
  }
  sb_putc(out, '"');
}

/* ---- markdown ---- */

static void md_cell(sbuf *out, const char *s, size_t n){
  int line_start = 1;   /* leading-space rule applies after \n only, not a lone \r */
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

/* ---- db2 ---- */

#ifndef SQL_DECFLOAT
#define SQL_DECFLOAT (-360)
#endif

static int align_right(SQLSMALLINT t){
  return t == SQL_SMALLINT || t == SQL_INTEGER || t == SQL_BIGINT
      || t == SQL_DECIMAL  || t == SQL_NUMERIC || t == SQL_REAL
      || t == SQL_FLOAT    || t == SQL_DOUBLE  || t == SQL_DECFLOAT;
}

/* quirk kept: the first diagnostic record only, with " SQLCODE=N" appended */
static int diag_text(SQLSMALLINT htype, SQLHANDLE h, sbuf *out){
  SQLCHAR state[SQL_SQLSTATE_SIZE + 1] = {0};
  SQLCHAR msg[SQL_MAX_MESSAGE_LENGTH + 1] = {0};
  SQLINTEGER native = 0;
  SQLSMALLINT len = 0;
  SQLRETURN rc = SQLGetDiagRec(htype, h, 1, state, &native, msg, sizeof msg, &len);
  if(rc != SQL_SUCCESS && rc != SQL_SUCCESS_WITH_INFO) return 0;
  /* the message ends in a newline: trim it, or SQLCODE lands on a line of its own */
  size_t mn = strlen((char *)msg);
  while(mn && php_space(((char *)msg)[mn - 1])) mn--;
  sb_putn(out, (char *)msg, mn);
  char t[40];
  snprintf(t, sizeof t, " SQLCODE=%ld", (long)native);
  sb_puts(out, t);
  return 1;
}

/* shortest %g that round-trips: as SQL_C_CHAR, 1.5 comes back as 1.50000000000000E+000.
   DECIMAL, NUMERIC and DECFLOAT arrive as exact strings and are not touched. */
static void fmt_double(sbuf *v, double d){
  char t[64];
  for(int p = 1; p <= 17; p++){
    snprintf(t, sizeof t, "%.*g", p, d);
    if(strtod(t, NULL) == d) break;
  }
  sb_puts(v, t);
}

/* the loop tests the indicator, not SQLSTATE 01004, so a non-truncation warning cannot spin */
static int get_col_text(SQLHSTMT h, SQLSMALLINT col, SQLSMALLINT type,
                        sbuf *v, int *isnull, sbuf *err){
  char buf[8192];
  SQLLEN ind = 0;
  *isnull = 0;
  v->len = 0;
  sb_reserve(v, 1);
  v->s[0] = 0;
  if(type == SQL_REAL || type == SQL_FLOAT || type == SQL_DOUBLE){
    double d = 0;
    SQLLEN dind = 0;
    SQLRETURN rc = SQLGetData(h, col, SQL_C_DOUBLE, &d, sizeof d, &dind);
    if(rc != SQL_SUCCESS && rc != SQL_SUCCESS_WITH_INFO){
      diag_text(SQL_HANDLE_STMT, h, err);
      return 0;
    }
    if(dind == SQL_NULL_DATA){ *isnull = 1; return 1; }
    fmt_double(v, d);
    return 1;
  }
  for(;;){
    SQLRETURN rc = SQLGetData(h, col, SQL_C_CHAR, buf, sizeof buf, &ind);
    if(rc == SQL_NO_DATA) break;
    if(rc != SQL_SUCCESS && rc != SQL_SUCCESS_WITH_INFO){
      diag_text(SQL_HANDLE_STMT, h, err);
      return 0;
    }
    if(ind == SQL_NULL_DATA){ *isnull = 1; return 1; }
    sb_putn(v, buf, strlen(buf));
    if(rc == SQL_SUCCESS) break;
    if(ind != SQL_NO_TOTAL && (SQLLEN)ind < (SQLLEN)sizeof buf) break;
  }
  return 1;
}

static long render_result(sbuf *md, SQLHSTMT h, SQLSMALLINT nf, sbuf *err){
  sbuf h2 = {0};
  int *ar = calloc((size_t)nf, sizeof *ar);
  SQLSMALLINT *ty = calloc((size_t)nf, sizeof *ty);
  if(!ar || !ty) oom();
  sb_puts(md, "|");
  sb_puts(&h2, "|");
  for(SQLSMALLINT i = 1; i <= nf; i++){
    SQLCHAR name[512] = {0};
    SQLSMALLINT namelen = 0, type = 0, dec = 0, nullable = 0;
    SQLULEN size = 0;
    SQLDescribeCol(h, i, name, sizeof name, &namelen, &type, &size, &dec, &nullable);
    size_t nl = strlen((char *)name);
    ar[i - 1] = align_right(type);
    ty[i - 1] = type;
    sb_putc(md, ' ');
    md_cell(md, (char *)name, nl);
    sb_puts(md, " |");
    /* dashes count the raw name, not the escaped one */
    sb_putc(&h2, ar[i - 1] ? '-' : ':');
    for(size_t j = 0; j < nl; j++) sb_putc(&h2, '-');
    sb_putc(&h2, ar[i - 1] ? ':' : '-');
    sb_putc(&h2, '|');
  }
  sb_putc(md, '\n');
  sb_putn(md, h2.s, h2.len);
  sb_putc(md, '\n');
  sb_free(&h2);
  free(ar);

  long nrows = 0;
  sbuf v = {0};
  for(;;){
    SQLRETURN rc = SQLFetch(h);
    if(rc == SQL_NO_DATA) break;
    if(rc != SQL_SUCCESS && rc != SQL_SUCCESS_WITH_INFO){
      diag_text(SQL_HANDLE_STMT, h, err);
      sb_free(&v);
      return -1;
    }
    sb_puts(md, "|");
    for(SQLSMALLINT j = 1; j <= nf; j++){
      int isnull = 0;
      sb_putc(md, ' ');
      if(!get_col_text(h, j, ty[j - 1], &v, &isnull, err)){ sb_free(&v); free(ty); return -1; }
      if(isnull) sb_puts(md, "*null*");
      else md_cell(md, v.s ? v.s : "", v.len);
      sb_puts(md, " |");
    }
    sb_putc(md, '\n');
    nrows++;
  }
  sb_free(&v);
  free(ty);
  return nrows;
}

/* quirk kept: strips every trailing ; without re-trimming the whitespace that exposes */
static void strip_trailing(char *s, size_t *n){
  size_t k = *n;
  while(k && php_space(s[k - 1])) k--;
  while(k && s[k - 1] == ';') k--;
  s[k] = 0;
  *n = k;
}

static void run_batch(sbuf *md, SQLHDBC hdbc, char *sql, size_t len){
  SQLHSTMT h = SQL_NULL_HSTMT;
  if(SQLAllocHandle(SQL_HANDLE_STMT, hdbc, &h) != SQL_SUCCESS){
    sbuf e = {0};
    if(diag_text(SQL_HANDLE_DBC, hdbc, &e)) fence_trimmed(md, e.s ? e.s : "", "error");
    sb_free(&e);
    return;
  }
  strip_trailing(sql, &len);
  SQLRETURN rc = SQLExecDirect(h, (SQLCHAR *)sql, SQL_NTS);
  sbuf err = {0};
  if(rc != SQL_SUCCESS && rc != SQL_SUCCESS_WITH_INFO){
    /* includes the empty batch, which the CLI rejects with CLI0124E */
    if(diag_text(SQL_HANDLE_STMT, h, &err)) fence_trimmed(md, err.s ? err.s : "", "error");
    sb_free(&err);
    SQLFreeHandle(SQL_HANDLE_STMT, h);
    return;
  }
  SQLSMALLINT nf = 0;
  SQLNumResultCols(h, &nf);
  char status[64];
  if(nf > 0){
    long n = render_result(md, h, nf, &err);
    if(n < 0){
      fence_trimmed(md, err.s ? err.s : "", "error");
      sb_free(&err);
      SQLFreeHandle(SQL_HANDLE_STMT, h);
      return;
    }
    snprintf(status, sizeof status, "%ld rows selected", n);
  } else {
    SQLLEN cnt = -1;
    SQLRowCount(h, &cnt);
    if(cnt >= 0) snprintf(status, sizeof status, "%ld rows affected", (long)cnt);
    else snprintf(status, sizeof status, "statement completed");
  }
  fence_block(md, status, strlen(status), "status");
  sb_free(&err);
  SQLFreeHandle(SQL_HANDLE_STMT, h);
}

/* ---- main ---- */

int main(int argc, char **argv){
  int warm = 0;
  const char *inpath = "/tmp/batches.json";
  const char *outpath = "/tmp/output.json";
  int pos = 0;
  for(int i = 1; i < argc; i++){
    if(!strcmp(argv[i], "--warmup")) warm = 1;
    else if(pos++ == 0) inpath = argv[i];
    else outpath = argv[i];
  }

  SQLHENV henv = SQL_NULL_HENV;
  SQLHDBC hdbc = SQL_NULL_HDBC;
  if(SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, &henv) != SQL_SUCCESS){
    fputs("SQLAllocHandle(ENV) failed\n", stderr);
    return 1;
  }
  SQLSetEnvAttr(henv, SQL_ATTR_ODBC_VERSION, (SQLPOINTER)SQL_OV_ODBC3, 0);
  if(SQLAllocHandle(SQL_HANDLE_DBC, henv, &hdbc) != SQL_SUCCESS){
    fputs("SQLAllocHandle(DBC) failed\n", stderr);
    return 1;
  }
  SQLRETURN rc = SQLConnect(hdbc, (SQLCHAR *)"FIDDLE", SQL_NTS, NULL, 0, NULL, 0);
  if(rc != SQL_SUCCESS && rc != SQL_SUCCESS_WITH_INFO){
    sbuf e = {0};
    diag_text(SQL_HANDLE_DBC, hdbc, &e);
    fprintf(stderr, "connect failed: %s\n", e.s ? e.s : "(no diagnostic)");
    return 1;
  }
  SQLSetConnectAttr(hdbc, SQL_ATTR_AUTOCOMMIT,
                    (SQLPOINTER)SQL_AUTOCOMMIT_ON, SQL_NTS);

  if(warm){
    /* prints the table: `warm-up:` in the ceremony log is the only evidence it connected */
    sbuf md = {0};
    char one[] = "values 1";
    run_batch(&md, hdbc, one, strlen(one));
    printf("warm-up: %.*s\n", (int)md.len, md.s ? md.s : "");
    sb_free(&md);
    SQLDisconnect(hdbc);
    return 0;
  }

  size_t blen = 0, nb = 0;
  char *btext = read_file(inpath, &blen);
  batch *batches = btext ? parse_batches(btext, &nb) : NULL;

  sbuf out = {0};
  sb_putc(&out, '[');
  for(size_t i = 0; i < nb; i++){
    sbuf md = {0};
    run_batch(&md, hdbc, batches[i].s, batches[i].len);
    if(i) sb_putc(&out, ',');
    json_emit_string(&out, md.s ? md.s : "", md.len);
    sb_free(&md);
  }
  sb_putc(&out, ']');
  SQLDisconnect(hdbc);

  FILE *f = fopen(outpath, "wb");
  if(!f) return 1;
  fwrite(out.s, 1, out.len, f);
  fclose(f);
  return 0;
}
EOC

# compile in the chroot: sqllib's include and lib64 are absolute symlinks, which from the host
# silently fail to find sqlcli1.h
chroot /mnt/fire/db2_11.1/mnt /usr/bin/gcc -O2 -Wall -o /fiddle /fiddle.c \
  -I/opt/ibm/db2/V11.1/include -L/opt/ibm/db2/V11.1/lib64 -ldb2 \
  -Wl,-rpath,/opt/ibm/db2/V11.1/lib64
chroot /mnt/fire/db2_11.1/mnt /usr/bin/ldd /fiddle
chmod 755 /mnt/fire/db2_11.1/mnt/fiddle

install -m 755 /mnt/fire/db2_11.1/vsock /mnt/fire/db2_11.1/mnt/vsock

umount /mnt/fire/db2_11.1/mnt
umount /mnt/db2xc111
docker rmi dummy_db2_11.1

# read the headroom after the umount: before it the superblock still shows the empty image
free_mb=$(dumpe2fs -h /mnt/fire/db2_11.1/rootfs.ext4 2>/dev/null \
  | awk '/^Free blocks:/{f=$3} /^Block size:/{b=$3} END{print int(f*b/1048576)}')
echo "rootfs free: ${free_mb}M"
[ "${free_mb:-0}" -ge 50 ] || { echo "FAIL: under 50M free - raise the dd count= above and rebuild"; exit 1; }

zfs set recordsize=16K tank/fire/db2_11.1

( cd /mnt/fire/db2_11.1
  rm -f mem vmstate v.sock* /tmp/fc-snap-db2_11.1.sock /tmp/fc-snap-db2_11.1.log
  firecracker-1.13 --api-sock /tmp/fc-snap-db2_11.1.sock --config-file config.json > /tmp/fc-snap-db2_11.1.log 2>&1 &
  until grep -qa FIDDLE-READY /tmp/fc-snap-db2_11.1.log ; do sleep 0.1 ; done
  curl -sf --unix-socket /tmp/fc-snap-db2_11.1.sock -X PATCH http://localhost/vm -H 'Content-Type: application/json' -d '{"state":"Paused"}'
  curl -sf --unix-socket /tmp/fc-snap-db2_11.1.sock -X PUT http://localhost/snapshot/create -H 'Content-Type: application/json' -d '{"snapshot_type":"Full","snapshot_path":"vmstate","mem_file_path":"mem"}'
  kill $! || true )
# a cold snapshot just serves slowly: check the warm-up ran and the boot arg took
grep -a 'warm-up:' /tmp/fc-snap-db2_11.1.log
grep -a 'Kernel command line' /tmp/fc-snap-db2_11.1.log | grep -q no-kvmapf || { echo "FAIL: no-kvmapf did not take"; exit 1; }
grep -qa 'Unknown kernel command line parameters' /tmp/fc-snap-db2_11.1.log && { echo "FAIL: kernel rejected a parameter"; exit 1; }

# never -R: on a live engine it destroys the clones of in-flight fiddles
zfs destroy tank/fire/db2_11.1@base 2>/dev/null || true
zfs snapshot tank/fire/db2_11.1@base

cd /
out=$(echo '["select 1 from sysibm.sysdummy1"]' | /mnt/fire/db2_11.1/run.sh) || true
printf '%s\n' "$out"
# run.sh has no meaningful exit status: assert on the body
[ -n "$out" ] || { echo "ABORT: verification fiddle returned an empty body"; exit 1; }
