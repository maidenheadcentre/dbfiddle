set -e

echo 'www-data        ALL=(ALL) NOPASSWD: /mnt/fire/mysql_5.6/run.sh' >> /etc/sudoers
zfs create tank/fire/mysql_5.6
cp /mnt/fire/vmlinux-5.10.223 /mnt/fire/mysql_5.6/vmlinux.bin

<<'EOF' cat > /mnt/fire/mysql_5.6/config.json
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

<<'EOF' cat > /mnt/fire/mysql_5.6/vsock.c
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
gcc -O2 -static -o /mnt/fire/mysql_5.6/vsock /mnt/fire/mysql_5.6/vsock.c

# never write listener.pl here: /mnt/fire/listener.pl is shared by every engine

<<'EOF' cat > /mnt/fire/mysql_5.6/run.sh
#!/bin/bash
# never pass "$@" through: the sudoers line has no argument spec, so any argument is
# permitted and the caller would be choosing the engine
exec /mnt/fire/run.sh "$(basename "$(dirname "$(readlink -f "$0")")")"
EOF

chmod 700 /mnt/fire/mysql_5.6/run.sh

mkdir /mnt/fire/mysql_5.6/mnt

<<'EOC' cat > /mnt/fire/mysql_5.6/fiddle.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
static ssize_t getrandom(void *buf, size_t len, unsigned int flags){
  return syscall(SYS_getrandom, buf, len, flags);
}
#include <mysql.h>

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

/* ---- result rendering ---- */

static int align_right(enum enum_field_types t){
  return t == MYSQL_TYPE_TINY || t == MYSQL_TYPE_SHORT || t == MYSQL_TYPE_LONG
      || t == MYSQL_TYPE_FLOAT || t == MYSQL_TYPE_DOUBLE
      || t == MYSQL_TYPE_LONGLONG || t == MYSQL_TYPE_INT24
      || t == MYSQL_TYPE_NEWDECIMAL;
}

/* a byte string is charset 63, never BINARY_FLAG: dates, binary-collated text and json
   set that flag too. char() and concat() also return 63, so those are CELL_MAYBE */
enum cell_kind { CELL_TEXT, CELL_HEX, CELL_BITS, CELL_MAYBE };

static enum cell_kind cell_kind_of(const MYSQL_FIELD *f){
  if(f->type == MYSQL_TYPE_BIT) return CELL_BITS;
  if(f->charsetnr != 63) return CELL_TEXT;
  switch(f->type){
    case MYSQL_TYPE_TINY_BLOB:
    case MYSQL_TYPE_BLOB:
    case MYSQL_TYPE_MEDIUM_BLOB:
    case MYSQL_TYPE_LONG_BLOB:
    case MYSQL_TYPE_GEOMETRY:
      return CELL_HEX;
    case MYSQL_TYPE_STRING:
    case MYSQL_TYPE_VAR_STRING:
      return CELL_MAYBE;
    default:
      return CELL_TEXT;
  }
}

/* the UTF-8 walk must match json_emit_string's: anything the emitter would replace
   with U+FFFD is hexed instead */
static int text_like(const char *s, unsigned long n){
  unsigned long i = 0;
  while(i < n){
    unsigned char c = (unsigned char)s[i];
    if(c < 0x20 && c != '\t' && c != '\n' && c != '\r') return 0;
    if(c < 0x80){ i++; continue; }
    int len = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC2 ? 2 : 0;
    if(!len || i + (unsigned long)len > n) return 0;
    for(int k = 1; k < len; k++)
      if(((unsigned char)s[i + k] & 0xC0) != 0x80) return 0;
    i += (unsigned long)len;
  }
  return 1;
}

/* the code span is load-bearing: md_cell escapes backticks, so no text value can pass for hex */
static void hex_cell(sbuf *out, const char *s, unsigned long n){
  static const char hexd[] = "0123456789ABCDEF";
  sb_puts(out, "`0x");
  for(unsigned long i = 0; i < n; i++){
    unsigned char b = (unsigned char)s[i];
    sb_putc(out, hexd[b >> 4]);
    sb_putc(out, hexd[b & 15]);
  }
  sb_putc(out, '`');
}

/* the value arrives as ceil(width/8) bytes, big-endian, zero-padded at the top */
static void bits_cell(sbuf *out, const char *s, unsigned long n,
                      unsigned long width){
  if(width == 0 || n != (width + 7) / 8){ hex_cell(out, s, n); return; }
  sb_puts(out, "`0b");
  for(unsigned long i = 0; i < width; i++){
    unsigned long bit = width - 1 - i;
    sb_putc(out, ((unsigned char)s[n - 1 - bit / 8] >> (bit % 8)) & 1 ? '1' : '0');
  }
  sb_putc(out, '`');
}

static void render_result(sbuf *md, MYSQL_RES *res){
  unsigned nf = mysql_num_fields(res);
  MYSQL_FIELD *f = mysql_fetch_fields(res);
  enum cell_kind *kind = malloc(nf * sizeof *kind);
  if(!kind) oom();

  /* per column, never per row: one column must not render two ways in one result */
  int scan = 0;
  for(unsigned i = 0; i < nf; i++){
    kind[i] = cell_kind_of(&f[i]);
    if(kind[i] == CELL_MAYBE) scan = 1;
  }
  if(scan){
    MYSQL_ROW r;
    while((r = mysql_fetch_row(res))){
      unsigned long *l = mysql_fetch_lengths(res);
      for(unsigned i = 0; i < nf; i++)
        if(kind[i] == CELL_MAYBE && r[i] && !text_like(r[i], l[i]))
          kind[i] = CELL_HEX;
    }
    mysql_data_seek(res, 0);
    for(unsigned i = 0; i < nf; i++)
      if(kind[i] == CELL_MAYBE) kind[i] = CELL_TEXT;
  }

  sbuf h2 = {0};
  sb_puts(md, "|");
  sb_puts(&h2, "|");
  for(unsigned i = 0; i < nf; i++){
    int ar = align_right(f[i].type);
    sb_putc(md, ' ');
    md_cell(md, f[i].name, f[i].name_length);
    sb_puts(md, " |");
    sb_putc(&h2, ar ? '-' : ':');
    for(unsigned j = 0; j < f[i].name_length; j++) sb_putc(&h2, '-');
    sb_putc(&h2, ar ? ':' : '-');
    sb_putc(&h2, '|');
  }
  sb_putc(md, '\n');
  sb_putn(md, h2.s, h2.len);
  sb_putc(md, '\n');
  sb_free(&h2);
  MYSQL_ROW row;
  while((row = mysql_fetch_row(res))){
    unsigned long *len = mysql_fetch_lengths(res);
    sb_puts(md, "|");
    for(unsigned j = 0; j < nf; j++){
      sb_putc(md, ' ');
      if(!row[j]) sb_puts(md, "*null*");
      else if(kind[j] == CELL_HEX) hex_cell(md, row[j], len[j]);
      else if(kind[j] == CELL_BITS) bits_cell(md, row[j], len[j], f[j].length);
      else md_cell(md, row[j], len[j]);
      sb_puts(md, " |");
    }
    sb_putc(md, '\n');
  }
  free(kind);
}

/* ---- main ---- */

static char *read_file(const char *path, size_t *n){
  FILE *f = fopen(path, "rb");
  if(!f) return NULL;
  sbuf b = {0};
  sb_reserve(&b, 1);
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

  MYSQL *conn = mysql_init(NULL);
  if(!conn) return 1;
  mysql_options(conn, MYSQL_SET_CHARSET_NAME, "utf8mb4");
  if(!mysql_real_connect(conn, "localhost", "root", NULL, "fiddle", 0,
                         "/var/run/mysqld/mysqld.sock", CLIENT_MULTI_STATEMENTS)){
    fputs("Could not connect to the server", stdout);
    return 1;
  }

  /* RAND() seeds derive from server-start state frozen into the snapshot -
     reseed per session */
  unsigned a = 0, b = 0;
  getrandom(&a, sizeof a, 0);
  getrandom(&b, sizeof b, 0);
  char seedq[80];
  snprintf(seedq, sizeof seedq, "set session rand_seed1=%u, rand_seed2=%u",
           1 + a % 0x3FFFFFFEu, 1 + b % 0x3FFFFFFEu);
  mysql_query(conn, seedq);

  size_t blen = 0, nb = 0;
  char *btext = read_file(inpath, &blen);
  batch *batches = btext ? parse_batches(btext, &nb) : NULL;

  sbuf out = {0};
  sb_putc(&out, '[');
  for(size_t i = 0; i < nb; i++){
    sbuf md = {0};
    if(mysql_real_query(conn, batches[i].s, batches[i].len) == 0){
      unsigned lasterrno = 0;
      char lasterr[2048] = "";
      for(;;){
        MYSQL_RES *res = mysql_store_result(conn);
        if(res){
          render_result(&md, res);
          mysql_free_result(res);
        } else if(mysql_errno(conn)){
          /* mysql_next_result clears result-stage errors (e.g. recursion limit):
             capture them now */
          lasterrno = mysql_errno(conn);
          snprintf(lasterr, sizeof lasterr, "%s", mysql_error(conn));
        }
        sb_putc(&md, '\n');
        const char *info = mysql_info(conn);
        if(info && *info) fence_block(&md, info, strlen(info), "status");
        if(mysql_next_result(conn) != 0) break;
      }
      if(mysql_errno(conn)){
        lasterrno = mysql_errno(conn);
        snprintf(lasterr, sizeof lasterr, "%s", mysql_error(conn));
      }
      if(lasterrno)
        fence_block(&md, lasterr, strlen(lasterr), "error");
    } else {
      fence_block(&md, mysql_error(conn), strlen(mysql_error(conn)), "error");
    }
    if(i) sb_putc(&out, ',');
    json_emit_string(&out, md.s ? md.s : "", md.len);
    sb_free(&md);
  }
  sb_putc(&out, ']');
  mysql_close(conn);

  FILE *f = fopen(outpath, "wb");
  if(!f) return 1;
  fwrite(out.s, 1, out.len, f);
  fclose(f);
  return 0;
}
EOC

cat > /mnt/fire/mysql_5.6/DOCKERFILE <<"EOF"
FROM mysql:5.6
RUN rm -f /etc/apt/sources.list.d/mysql.list
RUN printf 'deb http://archive.debian.org/debian stretch main\ndeb http://archive.debian.org/debian-security stretch/updates main\n' \
      > /etc/apt/sources.list \
 && echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99archive \
 && apt-get update \
 && apt-get install -y --no-install-recommends systemd-sysv udev haveged libmariadb2
# the image's own mysql.service starts after fiddle.sh's mysqld and takes it down, so the
# snapshot captures a guest with no server
RUN systemctl mask mysql.service
RUN mysql_install_db --user=mysql --ldata=/var/lib/mysql --basedir=/usr \
  && ( /usr/sbin/mysqld --user=root --skip-networking & ) \
  && sleep 10 \
  && mysql -e 'create database fiddle' mysql
RUN echo '[Service]' > /etc/systemd/system/fiddle.service \
  && echo 'ExecStart=/fiddle.sh' >> /etc/systemd/system/fiddle.service \
  && echo '[Install]' >> /etc/systemd/system/fiddle.service \
  && echo 'WantedBy=default.target' >> /etc/systemd/system/fiddle.service \
  && systemctl enable fiddle
RUN systemctl disable getty@tty1.service \
  && echo ttyS0 > /etc/securetty \
  && echo '[Service]' > /etc/systemd/system/mygetty.service \
  && echo 'ExecStart=/sbin/agetty -L 9600 ttyS0 vt102' >> /etc/systemd/system/mygetty.service \
  && echo '[Install]' >> /etc/systemd/system/mygetty.service \
  && echo 'WantedBy=default.target' >> /etc/systemd/system/mygetty.service \
  && systemctl enable mygetty
RUN apt-get clean && rm -rf /var/lib/apt/lists/*
RUN echo "root:Docker!" | chpasswd
ENTRYPOINT ["bash"]
EOF

DOCKER_BUILDKIT=1 docker build --no-cache -t dummy_mysql_5.6 - < /mnt/fire/mysql_5.6/DOCKERFILE
#docker run --rm -ti dummy_mysql_5.6
dd if=/dev/zero bs=1M count=543 > /mnt/fire/mysql_5.6/rootfs.ext4
mkfs.ext4 -m 0 /mnt/fire/mysql_5.6/rootfs.ext4
mount -o loop /mnt/fire/mysql_5.6/rootfs.ext4 /mnt/fire/mysql_5.6/mnt
cp /mnt/fire/mysql_5.6/fiddle.c /mnt/fire/mysql_5.6/mnt/fiddle.c
# the builder's release must match the guest's, or the runner links against a glibc the guest lacks
docker run --rm -v /mnt/fire/mysql_5.6/mnt:/my-rootfs debian:stretch-slim bash -c '
  set -e
  printf "deb http://archive.debian.org/debian stretch main\ndeb http://archive.debian.org/debian-security stretch/updates main\n" > /etc/apt/sources.list
  echo "Acquire::Check-Valid-Until \"false\";" > /etc/apt/apt.conf.d/99archive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends gcc libc6-dev libmariadb-dev
  gcc -O2 -Wall -o /my-rootfs/fiddle /my-rootfs/fiddle.c $(mariadb_config --cflags --libs)
  rm /my-rootfs/fiddle.c'
docker run --rm -ti -v /mnt/fire/mysql_5.6/mnt:/my-rootfs dummy_mysql_5.6
for d in bin etc home lib lib64 opt root sbin usr dev run var; do tar c "/$d" | tar x -C /my-rootfs; done
for dir in proc sys; do mkdir /my-rootfs/${dir}; done
mknod -m 666 /my-rootfs/dev/ttyS0 c 4 64
chroot /my-rootfs ldd /fiddle
exit

# drop the image: cumbria2's root filesystem fills otherwise
docker rmi dummy_mysql_5.6 || true

cp /mnt/fire/mysql_5.6/vsock /mnt/fire/mysql_5.6/mnt/vsock
chmod 755 /mnt/fire/mysql_5.6/mnt/vsock

# any edit to fiddle.sh or /fiddle invalidates the snapshot: re-run the ceremony
cat <<"EOF" > /mnt/fire/mysql_5.6/mnt/fiddle.sh
#!/bin/sh
dd if=/dev/random count=1 bs=1
mkdir /var/run/mysqld
# backdate the clock before mysqld seeds its openssl drbg, so the restore-time clock set
# pushes the drbg past its reseed interval and RANDOM_BYTES() reseeds after every restore
date -u -s @946684800
/usr/sbin/mysqld --user=root --skip-networking > /dev/null 2>&1 &
until [ -S /var/run/mysqld/mysqld.sock ] ; do sleep 0.1 ; done
echo '["select 1"]' > /tmp/warm.json
/fiddle /tmp/warm.json /tmp/warm.out
echo "warm-up: $(cat /tmp/warm.out)" > /dev/console
rm -f /tmp/warm.json /tmp/warm.out
sync
/vsock serve > /tmp/batches.json
/fiddle
/vsock reply < /tmp/output.json
reboot -ff
EOF

chmod 700 /mnt/fire/mysql_5.6/mnt/fiddle.sh

umount /mnt/fire/mysql_5.6/mnt

# read the headroom after the umount: before it the superblock still shows the empty image
dumpe2fs -h /mnt/fire/mysql_5.6/rootfs.ext4 2>/dev/null | awk '
  /^Block size:/ {bs=$3} /^Free blocks:/ {fb=$3}
  END {
    m = fb * bs / 1048576
    printf "rootfs headroom: %.1fM free (block size %d)\n", m, bs
    if (m < 50 || m > 100) {
      printf "ABORT: headroom %.1fM outside 50-100M - re-derive the dd count=\n", m
      exit 1
    }
  }' || exit 1

zfs set recordsize=16K tank/fire/mysql_5.6

cd /mnt/fire/mysql_5.6
rm -f mem vmstate v.sock* /tmp/fc-snap-mysql_5.6.sock /tmp/fc-snap-mysql_5.6.log
firecracker-1.13 --api-sock /tmp/fc-snap-mysql_5.6.sock --config-file config.json > /tmp/fc-snap-mysql_5.6.log 2>&1 &
until grep -q FIDDLE-READY /tmp/fc-snap-mysql_5.6.log ; do sleep 0.1 ; done
sleep 0.3
curl -sf --unix-socket /tmp/fc-snap-mysql_5.6.sock -X PATCH http://localhost/vm -H 'Content-Type: application/json' -d '{"state":"Paused"}'
curl -sf --unix-socket /tmp/fc-snap-mysql_5.6.sock -X PUT http://localhost/snapshot/create -H 'Content-Type: application/json' -d '{"snapshot_type":"Full","snapshot_path":"vmstate","mem_file_path":"mem"}'
kill $! || true

# leaked clones block the destroy, leaving a stale @base the snapshot line then trips on
# never -R: on a live engine it destroys the clones of in-flight fiddles
zfs destroy tank/fire/mysql_5.6@base 2>/dev/null || true
zfs snapshot tank/fire/mysql_5.6@base

# run.sh has no meaningful exit status: assert on the body
out=$(echo '["select version()"]' | /mnt/fire/mysql_5.6/run.sh) || true
printf '%s\n' "$out"
[ -n "$out" ] || { echo "ABORT: verification fiddle returned an empty body"; exit 1; }
