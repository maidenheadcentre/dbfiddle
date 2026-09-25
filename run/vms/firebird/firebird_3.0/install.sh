echo 'www-data        ALL=(ALL) NOPASSWD: /mnt/fire/firebird_3.0/run.sh' >> /etc/sudoers
zfs create tank/fire/firebird_3.0
cp /mnt/fire/vmlinux-5.10.223 /mnt/fire/firebird_3.0/vmlinux.bin

<<'EOF' cat > /mnt/fire/firebird_3.0/config.json
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

<<'EOF' cat > /mnt/fire/firebird_3.0/vsock.c
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
gcc -O2 -static -o /mnt/fire/firebird_3.0/vsock /mnt/fire/firebird_3.0/vsock.c

# never write listener.pl here: /mnt/fire/listener.pl is shared by every engine

<<'EOF' cat > /mnt/fire/firebird_3.0/run.sh
#!/bin/bash
# never pass "$@" through: the sudoers line has no argument spec, so any argument is
# permitted and the caller would be choosing the engine
exec /mnt/fire/run.sh "$(basename "$(dirname "$(readlink -f "$0")")")"
EOF

chmod 700 /mnt/fire/firebird_3.0/run.sh

mkdir /mnt/fire/firebird_3.0/mnt

# ---- which Firebird, and from where ----
# the libtommath link is relative: the builder compiles against this rootfs at
# /my-rootfs, where an absolute one resolves to nothing
<<'EODOCKER' cat > /mnt/fire/firebird_3.0/DOCKERFILE
FROM debian:bookworm-slim
RUN apt-get update && apt-get install --no-install-recommends -y \
      systemd-sysv udev haveged ca-certificates curl libicu72 libtommath1 libncurses5 libtinfo5 libatomic1
RUN curl -sfLo /tmp/fb.tar.gz https://github.com/FirebirdSQL/firebird/releases/download/v3.0.14/Firebird-3.0.14.33856-0.amd64.tar.gz \
 && echo "d6fedba1108a46cea2b5f753674046fff0e43c6af27ba01657511635cbc9670f  /tmp/fb.tar.gz" | sha256sum -c - \
 && tar xzf /tmp/fb.tar.gz -C /tmp \
 && tar xzf /tmp/Firebird-3.0.14.33856-0.amd64/buildroot.tar.gz -C / \
 && rm -rf /tmp/fb.tar.gz /tmp/Firebird-3.0.14.33856-0.amd64 \
 && echo /opt/firebird/lib > /etc/ld.so.conf.d/firebird.conf \
 && ln -sf libtommath.so.1 /usr/lib/x86_64-linux-gnu/libtommath.so.0 \
 && ldconfig \
 && ldd /opt/firebird/lib/libfbclient.so.2 | grep -q 'not found' && exit 1 || true
RUN rm -rf /opt/firebird/examples /opt/firebird/doc /opt/firebird/misc /opt/firebird/help
RUN printf "create database '/fiddle.fdb' default character set utf8;\nquit;\n" > /tmp/mk.sql \
 && /opt/firebird/bin/isql -q -i /tmp/mk.sql \
 && rm -f /tmp/mk.sql \
 && printf "select rdb\$get_context('SYSTEM','ENGINE_VERSION') from rdb\$database;\nquit;\n" > /tmp/v.sql \
 && /opt/firebird/bin/isql -q /fiddle.fdb -i /tmp/v.sql && rm -f /tmp/v.sql
RUN echo '[Service]' > /etc/systemd/system/fiddle.service \
  && echo 'ExecStart=/fiddle.sh' >> /etc/systemd/system/fiddle.service \
  && echo '[Install]' >> /etc/systemd/system/fiddle.service \
  && echo 'WantedBy=default.target' >> /etc/systemd/system/fiddle.service \
  && systemctl enable fiddle
RUN apt-get clean && rm -rf /var/lib/apt/lists/*
RUN echo "root:Docker!" | chpasswd
ENTRYPOINT ["bash"]
EODOCKER

# ---- the fiddle runner ----
<<'EOC' cat > /mnt/fire/firebird_3.0/fiddle.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ibase.h>

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
    s.s[0] = 0;
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

/* ---- statement splitting ----
   Saved fiddles use both isql style, with SET TERM, and whole PSQL bodies without it,
   so a plain split on `;` breaks them. A terminator ends a statement only at BEGIN/CASE
   depth 0, and never between a body's AS and its first BEGIN, where DECLARE sits. */

typedef struct {
  const char *p;
  char term[64];
  size_t termlen;
} splitter;

static int ident_char(char c){
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9') || c == '_' || c == '$';
}

static int word_at(const char *s, const char *start, const char *kw){
  size_t n = strlen(kw);
  for(size_t i = 0; i < n; i++){
    char c = s[i];
    if(c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
    if(c != kw[i]) return 0;
  }
  if(ident_char(s[n])) return 0;
  if(s > start && ident_char(s[-1])) return 0;
  return (int)n;
}

static const char *skip_ws_comments(const char *s){
  for(;;){
    while(*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    if(s[0] == '-' && s[1] == '-'){ while(*s && *s != '\n') s++; continue; }
    if(s[0] == '/' && s[1] == '*'){
      s += 2;
      while(*s && !(*s == '*' && s[1] == '/')) s++;
      if(*s) s += 2;
      continue;
    }
    return s;
  }
}

static int has_psql_body(const char *s){
  const char *p = skip_ws_comments(s);
  int n;
  if((n = word_at(p, p, "EXECUTE"))){
    p = skip_ws(p + n);
    return word_at(p, p, "BLOCK") != 0;
  }
  if(!((n = word_at(p, p, "CREATE")) || (n = word_at(p, p, "RECREATE"))
       || (n = word_at(p, p, "ALTER")))) return 0;
  p = skip_ws(p + n);
  if((n = word_at(p, p, "OR"))){
    p = skip_ws(p + n);
    if((n = word_at(p, p, "ALTER"))) p = skip_ws(p + n);
  }
  return word_at(p, p, "PROCEDURE") || word_at(p, p, "TRIGGER")
      || word_at(p, p, "FUNCTION") || word_at(p, p, "PACKAGE");
}

static int split_next(splitter *sp, sbuf *out){
  const char *s = sp->p;
  const char *start = s;
  int depth = 0;
  int psql = has_psql_body(s), seen_as = 0, seen_begin = 0;
  out->len = 0;
  if(out->s) out->s[0] = 0;

  for(;;){
    char c = *s;
    if(!c) break;
    if(c == '\''){
      const char *b = s++;
      while(*s && !(*s == '\'' && *++s != '\'')) s++;
      sb_putn(out, b, (size_t)(s - b));
      continue;
    }
    if(c == '"'){
      const char *b = s++;
      while(*s && !(*s == '"' && *++s != '"')) s++;
      sb_putn(out, b, (size_t)(s - b));
      continue;
    }
    if(c == '-' && s[1] == '-'){
      const char *b = s;
      while(*s && *s != '\n') s++;
      sb_putn(out, b, (size_t)(s - b));
      continue;
    }
    if(c == '/' && s[1] == '*'){
      const char *b = s;
      s += 2;
      while(*s && !(*s == '*' && s[1] == '/')) s++;
      if(*s) s += 2;
      sb_putn(out, b, (size_t)(s - b));
      continue;
    }
    if(depth == 0 && !(psql && seen_as && !seen_begin) && sp->termlen
       && !strncmp(s, sp->term, sp->termlen)){
      s += sp->termlen;
      sp->p = s;
      return 1;
    }
    if(ident_char(c) && (s == start || !ident_char(s[-1]))){
      int n;
      /* CASE counts for depth but is not the body's BEGIN: a `case ... end` in the
         DECLARE section would otherwise expose the `;` after it */
      if((n = word_at(s, start, "BEGIN"))){ depth++; seen_begin = 1; }
      else if((n = word_at(s, start, "CASE"))) depth++;
      else if((n = word_at(s, start, "END"))){ if(depth) depth--; }
      else if((n = word_at(s, start, "AS"))) seen_as = 1;
      if(n){ sb_putn(out, s, (size_t)n); s += n; continue; }
    }
    sb_putc(out, c);
    s++;
  }
  sp->p = s;
  for(size_t i = 0; i < out->len; i++)
    if(!strchr(" \t\r\n", out->s[i])) return 1;
  return 0;
}

static int stmt_is_blank(const char *s){ return *skip_ws_comments(s) == 0; }

static int take_set_term(splitter *sp, const char *stmt){
  const char *p = skip_ws(stmt);
  if(!word_at(p, p, "SET")) return 0;
  p = skip_ws(p + 3);
  if(!word_at(p, p, "TERM")) return 0;
  p = skip_ws(p + 4);
  size_t n = 0;
  while(p[n] && !strchr(" \t\r\n", p[n]) && n < sizeof sp->term - 1) n++;
  if(!n) return 0;
  memcpy(sp->term, p, n);
  sp->term[n] = 0;
  sp->termlen = n;
  return 1;
}

/* up to 4.0, DML ... RETURNING has the same statement type as EXECUTE PROCEDURE, but a
   procedure's all-null row must render where a RETURNING that matched nothing must not:
   only the text separates them */
static int is_execute_procedure(const char *s){
  const char *p = skip_ws_comments(s);
  int n = word_at(p, p, "EXECUTE");
  if(!n) return 0;
  p = skip_ws_comments(p + n);
  return word_at(p, p, "PROCEDURE") != 0;
}

/* ---- firebird ---- */

static ISC_STATUS_ARRAY status;

static void status_text(sbuf *e){
  const ISC_STATUS *p = status;
  char buf[512];
  int first = 1;
  while(fb_interpret(buf, sizeof buf, &p)){
    if(!first) sb_putc(e, '\n');
    sb_puts(e, buf);
    first = 0;
  }
  if(first) sb_puts(e, "unknown Firebird error");
}

static int align_right(short dtype){
  switch(dtype){
    case SQL_SHORT: case SQL_LONG: case SQL_INT64:
    case SQL_FLOAT: case SQL_DOUBLE: case SQL_D_FLOAT:
#ifdef SQL_INT128
    case SQL_INT128:
#endif
#ifdef SQL_DEC16
    case SQL_DEC16: case SQL_DEC34:
#endif
      return 1;
    default: return 0;
  }
}

/* scalars are coerced to VARYING and converted by the engine; 256 bytes covers every
   one (DECFLOAT(34) ~42, TIMESTAMP WITH TIME ZONE ~60) */
static void prepare_sqlda(XSQLDA *da, int *align, int *octets){
  for(int i = 0; i < da->sqld; i++){
    XSQLVAR *v = &da->sqlvar[i];
    short dtype = v->sqltype & ~1;
    align[i] = align_right(dtype);
    /* the low byte of sqlsubtype is the charset id, 1 = OCTETS: read it before the
       coercion below rewrites sqltype */
    octets[i] = (dtype == SQL_TEXT || dtype == SQL_VARYING)
             && (v->sqlsubtype & 0xFF) == 1;
    if(dtype == SQL_BLOB || dtype == SQL_ARRAY){
      v->sqldata = malloc(sizeof(ISC_QUAD));
    } else if(dtype == SQL_TIMESTAMP){
      /* never coerce TIMESTAMP: 3.0 converts it to DD-MON-YYYY text where 4.0 and 5.0
         give ISO, and decoding it here gives ISO on all three */
      v->sqldata = malloc(sizeof(ISC_TIMESTAMP));
    } else {
      short len = (dtype == SQL_TEXT || dtype == SQL_VARYING) ? v->sqllen : 256;
      v->sqltype = SQL_VARYING | 1;
      v->sqllen = len;
      v->sqldata = malloc((size_t)len + 2);
    }
    if(!v->sqldata) oom();
    v->sqltype |= 1;
    v->sqlind = malloc(sizeof(short));
    if(!v->sqlind) oom();
    *v->sqlind = 0;
  }
}

static void free_sqlda_buffers(XSQLDA *da){
  for(int i = 0; i < da->sqld; i++){
    free(da->sqlvar[i].sqldata);
    free(da->sqlvar[i].sqlind);
    da->sqlvar[i].sqldata = NULL;
    da->sqlvar[i].sqlind = NULL;
  }
}

static const char hexd[] = "0123456789abcdef";

static void put_hex(sbuf *md, const char *s, size_t n){
  for(size_t i = 0; i < n; i++){
    unsigned char b = (unsigned char)s[i];
    sb_putc(md, hexd[b >> 4]);
    sb_putc(md, hexd[b & 15]);
  }
}

static void render_blob(sbuf *md, isc_db_handle *db, isc_tr_handle *tr,
                        ISC_QUAD *id, short subtype){
  isc_blob_handle bh = 0;
  if(isc_open_blob2(status, db, tr, &bh, id, 0, NULL)){
    sb_puts(md, "*blob*");
    return;
  }
  sbuf raw = {0};
  char seg[16384];
  unsigned short slen = 0;
  for(;;){
    ISC_STATUS rc = isc_get_segment(status, &bh, &slen, sizeof seg, seg);
    if(rc == 0 || rc == isc_segment) sb_putn(&raw, seg, slen);
    else break;
  }
  isc_close_blob(status, &bh);
  if(subtype == 1) md_cell(md, raw.s ? raw.s : "", raw.len);
  else put_hex(md, raw.s ? raw.s : "", raw.len);
  sb_free(&raw);
}

static void render_row(sbuf *md, XSQLDA *da, const int *octets,
                       isc_db_handle *db, isc_tr_handle *tr){
  sb_puts(md, "|");
  for(int i = 0; i < da->sqld; i++){
    XSQLVAR *v = &da->sqlvar[i];
    short dtype = v->sqltype & ~1;
    sb_putc(md, ' ');
    if((v->sqltype & 1) && v->sqlind && *v->sqlind == -1) sb_puts(md, "*null*");
    else if(dtype == SQL_BLOB) render_blob(md, db, tr, (ISC_QUAD *)v->sqldata, v->sqlsubtype);
    else if(dtype == SQL_ARRAY) sb_puts(md, "*array*");
    else if(dtype == SQL_TIMESTAMP){
      ISC_TIMESTAMP ts;
      memcpy(&ts, v->sqldata, sizeof ts);
      struct tm tm;
      isc_decode_timestamp(&ts, &tm);
      /* timestamp_time counts ten-thousandths of a second: Firebird's own four places */
      char b[48];
      int n = snprintf(b, sizeof b, "%04d-%02d-%02d %02d:%02d:%02d.%04d",
                       tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                       tm.tm_hour, tm.tm_min, tm.tm_sec,
                       (int)(ts.timestamp_time % 10000));
      md_cell(md, b, (size_t)n);
    }
    else {
      short len;
      memcpy(&len, v->sqldata, sizeof len);
      if(octets[i]) put_hex(md, v->sqldata + 2, (size_t)len);
      else md_cell(md, v->sqldata + 2, (size_t)len);
    }
    sb_puts(md, " |");
  }
  sb_putc(md, '\n');
}

static void render_header(sbuf *md, XSQLDA *da, const int *align){
  sbuf h2 = {0};
  sb_puts(md, "|");
  sb_puts(&h2, "|");
  for(int i = 0; i < da->sqld; i++){
    XSQLVAR *v = &da->sqlvar[i];
    size_t nl = (size_t)v->aliasname_length;
    sb_putc(md, ' ');
    md_cell(md, v->aliasname, nl);
    sb_puts(md, " |");
    sb_putc(&h2, align[i] ? '-' : ':');
    for(size_t j = 0; j < nl; j++) sb_putc(&h2, '-');
    sb_putc(&h2, align[i] ? ':' : '-');
    sb_putc(&h2, '|');
  }
  sb_putc(md, '\n');
  sb_putn(md, h2.s, h2.len);
  sb_putc(md, '\n');
  sb_free(&h2);
}

static int stmt_type(isc_stmt_handle *st){
  char items[] = { isc_info_sql_stmt_type };
  char buf[64];
  if(isc_dsql_sql_info(status, st, sizeof items, items, sizeof buf, buf)) return 0;
  if(buf[0] != isc_info_sql_stmt_type) return 0;
  short l = (short)isc_vax_integer(buf + 1, 2);
  return (int)isc_vax_integer(buf + 3, l);
}

static int affected_rows(isc_stmt_handle *st){
  char items[] = { isc_info_sql_records };
  char buf[128];
  if(isc_dsql_sql_info(status, st, sizeof items, items, sizeof buf, buf)) return 0;
  if(buf[0] != isc_info_sql_records) return 0;
  int total = 0;
  char *p = buf + 3;
  while(*p != isc_info_end){
    char item = *p++;
    short l = (short)isc_vax_integer(p, 2);
    p += 2;
    int n = (int)isc_vax_integer(p, l);
    p += l;
    if(item == isc_info_req_insert_count || item == isc_info_req_update_count
       || item == isc_info_req_delete_count) total += n;
  }
  return total;
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

#define DBPATH "/fiddle.fdb"

static isc_db_handle db = 0;

/* one statement, one transaction, as isql's AUTOCOMMIT: DDL must be committed before
   the next statement in the batch prepares */
static int run_statement(const char *sql, sbuf *md){
  isc_tr_handle tr = 0;
  isc_stmt_handle st = 0;
  XSQLDA *da = NULL;
  int *align = NULL, *octets = NULL;
  int failed = 0;
  sbuf err = {0};

  if(isc_start_transaction(status, &tr, 1, &db, 0, NULL)) goto fail;
  if(isc_dsql_allocate_statement(status, &db, &st)) goto fail;

  da = malloc(XSQLDA_LENGTH(16));
  if(!da) oom();
  memset(da, 0, XSQLDA_LENGTH(16));
  da->version = SQLDA_VERSION1;
  da->sqln = 16;

  if(isc_dsql_prepare(status, &tr, &st, 0, sql, SQL_DIALECT_CURRENT, da)) goto fail;
  if(da->sqld > da->sqln){
    short n = da->sqld;
    free(da);
    da = malloc(XSQLDA_LENGTH(n));
    if(!da) oom();
    memset(da, 0, XSQLDA_LENGTH(n));
    da->version = SQLDA_VERSION1;
    da->sqln = n;
    if(isc_dsql_describe(status, &st, SQL_DIALECT_CURRENT, da)) goto fail;
  }

  int type = stmt_type(&st);
  int exec_proc = is_execute_procedure(sql);
  int cursor = (type == isc_info_sql_stmt_select
             || type == isc_info_sql_stmt_select_for_upd);
  int dml = (type == isc_info_sql_stmt_insert || type == isc_info_sql_stmt_update
          || type == isc_info_sql_stmt_delete);

  if(da->sqld > 0){
    align = malloc((size_t)da->sqld * sizeof *align);
    octets = malloc((size_t)da->sqld * sizeof *octets);
    if(!align || !octets) oom();
    prepare_sqlda(da, align, octets);
  }

  if(cursor || da->sqld == 0){
    if(isc_dsql_execute(status, &tr, &st, SQL_DIALECT_CURRENT, NULL)) goto fail;
  } else {
    if(isc_dsql_execute2(status, &tr, &st, SQL_DIALECT_CURRENT, NULL, da)) goto fail;
  }

  if(da->sqld > 0){
    if(cursor){
      sbuf rows = {0};
      int nrows = 0;
      ISC_STATUS fr;
      while((fr = isc_dsql_fetch(status, &st, SQL_DIALECT_CURRENT, da)) == 0){
        nrows++;
        render_row(&rows, da, octets, &db, &tr);
      }
      if(fr != 100L){
        if(nrows){
          render_header(md, da, align);
          sb_putn(md, rows.s, rows.len);
        }
        sb_free(&rows);
        goto fail;
      }
      render_header(md, da, align);
      if(rows.len) sb_putn(md, rows.s, rows.len);
      sb_free(&rows);
    } else {
      render_header(md, da, align);
      if(exec_proc || affected_rows(&st) > 0) render_row(md, da, octets, &db, &tr);
    }
  }

  if(dml){
    char tag[64];
    int n = affected_rows(&st);
    int l = snprintf(tag, sizeof tag, "%d row%s affected", n, n == 1 ? "" : "s");
    fence_block(md, tag, (size_t)l, "status");
  } else if(da->sqld == 0){
    /* no result: renders empty, with no command tag to fence */
  } else {
    sb_putc(md, '\n');
  }

  goto done;

fail:
  failed = 1;
  status_text(&err);
  fence_block(md, err.s ? err.s : "", err.len, "error");
  sb_free(&err);

done:
  if(da){
    if(da->sqld > 0) free_sqlda_buffers(da);
    free(da);
  }
  free(align);
  free(octets);
  if(st) isc_dsql_free_statement(status, &st, DSQL_drop);
  if(tr){
    if(failed) isc_rollback_transaction(status, &tr);
    else if(isc_commit_transaction(status, &tr)){
      sbuf e2 = {0};
      status_text(&e2);
      fence_block(md, e2.s ? e2.s : "", e2.len, "error");
      sb_free(&e2);
      isc_rollback_transaction(status, &tr);
      failed = 1;
    }
  }
  return !failed;
}

int main(int argc, char **argv){
  const char *inpath = argc > 1 ? argv[1] : "/tmp/batches.json";
  const char *outpath = argc > 2 ? argv[2] : "/tmp/output.json";

  char dpb[64];
  char *d = dpb;
  *d++ = isc_dpb_version1;
  *d++ = isc_dpb_lc_ctype;
  *d++ = 4;
  memcpy(d, "UTF8", 4);
  d += 4;

  if(isc_attach_database(status, 0, DBPATH, &db, (short)(d - dpb), dpb)){
    fputs("Could not connect to the server", stdout);
    return 1;
  }

  size_t blen = 0, nb = 0;
  char *btext = read_file(inpath, &blen);
  batch *batches = btext ? parse_batches(btext, &nb) : NULL;

  sbuf out = {0};
  sb_putc(&out, '[');
  for(size_t i = 0; i < nb; i++){
    sbuf md = {0};
    splitter sp = { batches[i].s, ";", 1 };
    sbuf stmt = {0};
    while(split_next(&sp, &stmt)){
      if(take_set_term(&sp, stmt.s ? stmt.s : "")) continue;
      if(stmt_is_blank(stmt.s ? stmt.s : "")) continue;
      if(!run_statement(stmt.s, &md)) break;
    }
    sb_free(&stmt);
    if(i) sb_putc(&out, ',');
    json_emit_string(&out, md.s ? md.s : "", md.len);
    sb_free(&md);
  }
  sb_putc(&out, ']');
  isc_detach_database(status, &db);

  FILE *f = fopen(outpath, "wb");
  if(!f) return 1;
  fwrite(out.s, 1, out.len, f);
  fclose(f);
  return 0;
}
EOC

# per-engine tag: concurrent builds on cumbria2 must never share one
DOCKER_BUILDKIT=1 docker build --no-cache -t dummy_firebird_3.0 - < /mnt/fire/firebird_3.0/DOCKERFILE

# 285M: a 196M tree plus fiddle.fdb and ~8M of ext4 overhead leaves 81M free
dd if=/dev/zero bs=1M count=285 > /mnt/fire/firebird_3.0/rootfs.ext4
mkfs.ext4 -m 0 /mnt/fire/firebird_3.0/rootfs.ext4
mount -o loop /mnt/fire/firebird_3.0/rootfs.ext4 /mnt/fire/firebird_3.0/mnt
docker run --rm -ti -v /mnt/fire/firebird_3.0/mnt:/my-rootfs dummy_firebird_3.0
for d in bin etc home lib lib64 opt root sbin usr dev var; do tar c "/$d" | tar x -C /my-rootfs; done
for dir in run proc sys; do mkdir /my-rootfs/${dir}; done
cp /fiddle.fdb /my-rootfs/fiddle.fdb
mknod -m 666 /my-rootfs/dev/ttyS0 c 4 64
exit

# -I the /opt tree, not /usr/include: buildroot's symlink there is absolute and resolves
# only inside the guest
cp /mnt/fire/firebird_3.0/fiddle.c /mnt/fire/firebird_3.0/mnt/fiddle.c
docker run --rm -v /mnt/fire/firebird_3.0/mnt:/my-rootfs debian:bookworm-slim bash -c '
  set -e
  apt-get update -qq && apt-get install -y -qq --no-install-recommends gcc libc6-dev
  gcc -O2 -Wall -o /my-rootfs/fiddle /my-rootfs/fiddle.c \
      -I/my-rootfs/opt/firebird/include \
      -L/my-rootfs/opt/firebird/lib -lfbclient \
      -Wl,-rpath-link,/my-rootfs/opt/firebird/lib:/my-rootfs/usr/lib/x86_64-linux-gnu
  rm /my-rootfs/fiddle.c'
chroot /mnt/fire/firebird_3.0/mnt /usr/bin/ldd /fiddle

docker rmi dummy_firebird_3.0

cp /mnt/fire/firebird_3.0/vsock /mnt/fire/firebird_3.0/mnt/vsock
chmod 755 /mnt/fire/firebird_3.0/mnt/vsock

# any edit to fiddle.sh or /fiddle invalidates the snapshot: re-run the ceremony
cat <<"EOF" > /mnt/fire/firebird_3.0/mnt/fiddle.sh
#!/bin/sh
dd if=/dev/random count=1 bs=1
echo '["select 1 from rdb$database"]' > /tmp/warm.json
/fiddle /tmp/warm.json /tmp/warm.out
echo "warm-up: $(cat /tmp/warm.out)" > /dev/console
rm -f /tmp/warm.json /tmp/warm.out
sync
/vsock serve > /tmp/batches.json
/fiddle
/vsock reply < /tmp/output.json
reboot -ff
EOF

chmod 700 /mnt/fire/firebird_3.0/mnt/fiddle.sh

umount /mnt/fire/firebird_3.0/mnt

# read the headroom after the umount: before it the superblock still shows the empty image
dumpe2fs -h /mnt/fire/firebird_3.0/rootfs.ext4 2>/dev/null | grep -E 'Block (count|size)|Free blocks'
blk=$(dumpe2fs -h /mnt/fire/firebird_3.0/rootfs.ext4 2>/dev/null | awk '/^Block size:/{print $3}')
free_mb=$(( $(dumpe2fs -h /mnt/fire/firebird_3.0/rootfs.ext4 2>/dev/null | awk '/^Free blocks:/{print $3}') * blk / 1048576 ))
echo "rootfs free: ${free_mb}M (target 50-100M)"
[ "$free_mb" -ge 50 ] || { echo "FAIL: rootfs headroom ${free_mb}M below the 50M floor - raise dd count"; exit 1; }

zfs set recordsize=16K tank/fire/firebird_3.0

cd /mnt/fire/firebird_3.0
rm -f mem vmstate v.sock* /tmp/fc-snap-firebird_3.0.sock /tmp/fc-snap-firebird_3.0.log
firecracker-1.13 --api-sock /tmp/fc-snap-firebird_3.0.sock --config-file config.json > /tmp/fc-snap-firebird_3.0.log 2>&1 &
until grep -q FIDDLE-READY /tmp/fc-snap-firebird_3.0.log ; do sleep 0.1 ; done
# proves the warm-up ran: a runner that failed to compile shows up nowhere else
grep -a 'warm-up:' /tmp/fc-snap-firebird_3.0.log
sleep 0.3
curl -sf --unix-socket /tmp/fc-snap-firebird_3.0.sock -X PATCH http://localhost/vm -H 'Content-Type: application/json' -d '{"state":"Paused"}'
curl -sf --unix-socket /tmp/fc-snap-firebird_3.0.sock -X PUT http://localhost/snapshot/create -H 'Content-Type: application/json' -d '{"snapshot_type":"Full","snapshot_path":"vmstate","mem_file_path":"mem"}'
kill $! || true

# never -R: against a live engine it destroys the clones of in-flight fiddles
zfs destroy tank/fire/firebird_3.0@base 2>/dev/null || true
zfs snapshot tank/fire/firebird_3.0@base

out=$(echo '["select rdb$get_context('"'"'SYSTEM'"'"','"'"'ENGINE_VERSION'"'"') as v from rdb$database"]' | /mnt/fire/firebird_3.0/run.sh) || true
printf '%s\n' "$out"
# run.sh has no meaningful exit status: assert on the body
[ -n "$out" ] || { echo "ABORT: verification fiddle returned an empty body"; exit 1; }
