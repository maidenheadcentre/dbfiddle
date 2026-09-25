echo 'www-data        ALL=(ALL) NOPASSWD: /mnt/fire/duckdb_1.4/run.sh' >> /etc/sudoers
zfs create tank/fire/duckdb_1.4
cp /mnt/fire/vmlinux-5.10.223 /mnt/fire/duckdb_1.4/vmlinux.bin

<<'EOF' cat > /mnt/fire/duckdb_1.4/config.json
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

<<'EOF' cat > /mnt/fire/duckdb_1.4/vsock.c
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
gcc -O2 -static -o /mnt/fire/duckdb_1.4/vsock /mnt/fire/duckdb_1.4/vsock.c

# never write listener.pl here: /mnt/fire/listener.pl is shared by every engine

<<'EOF' cat > /mnt/fire/duckdb_1.4/run.sh
#!/bin/bash
# never pass "$@" through: the sudoers line has no argument spec, so any argument is
# permitted and the caller would be choosing the engine
exec /mnt/fire/run.sh "$(basename "$(dirname "$(readlink -f "$0")")")"
EOF

chmod 700 /mnt/fire/duckdb_1.4/run.sh

mkdir /mnt/fire/duckdb_1.4/mnt
# C++, not the C API: its row accessors return empty strings for LIST/STRUCT columns
<<'EOC' cat > /mnt/fire/duckdb_1.4/fiddle.cc
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <sys/wait.h>
#include <memory>
#include "duckdb.hpp"

static void oom(void){ fputs("out of memory\n", stderr); exit(1); }

/* ---- growable string buffer ---- */

typedef struct { char *s; size_t len, cap; } sbuf;

static void sb_reserve(sbuf *b, size_t extra){
  if(b->len + extra + 1 <= b->cap) return;
  size_t cap = b->cap ? b->cap : 256;
  while(cap < b->len + extra + 1) cap *= 2;
  char *s = (char *)realloc(b->s, cap);
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

static batch *parse_payload(const char *text, size_t *count){
  size_t cap = 8, n = 0;
  batch *v = (batch *)malloc(cap * sizeof *v);
  if(!v) oom();
  const char *p = skip_ws(text);
  if(*p != '[') goto fail;
  p = skip_ws(p + 1);
  if(*p == ']'){ p++; goto done; }
  for(;;){
    sbuf s = {0}, l = {0};
    sb_reserve(&s, 1);
    s.s[0] = 0;   /* an empty batch never reaches sb_putn's terminator */
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
      v = (batch *)realloc(v, cap * sizeof *v);
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

static const char *lang_interp(const char *lang){
  if(!strcmp(lang, "python")) return "/usr/bin/python3";
  if(!strcmp(lang, "node")) return "/usr/local/bin/node";
  return NULL;
}
static const char *lang_suffix(const char *lang){
  return !strcmp(lang, "python") ? "py" : "js";
}

/* fork() beside a live duckdb instance, which runs threads, is safe only because the
   child execs immediately */
static int run_batch(const batch *b, size_t idx, const char *interp, const char *sfx,
                     sbuf *so, sbuf *se, int *status, long deadline){
  int op[2], ep[2];
  if(pipe(op) < 0 || pipe(ep) < 0) return 0;

  char path[64];
  snprintf(path, sizeof path, "/tmp/batch%zu.%s", idx + 1, sfx);
  FILE *f = fopen(path, "wb");
  if(!f) return 0;
  fwrite(b->s, 1, b->len, f);
  fclose(f);

  pid_t pid = fork();
  if(pid < 0) return 0;
  if(pid == 0){
    /* /dev/null on stdin, or a batch that reads it blocks until the deadline */
    int nul = open("/dev/null", O_RDONLY);
    dup2(nul, 0); dup2(op[1], 1); dup2(ep[1], 2);
    close(op[0]); close(op[1]); close(ep[0]); close(ep[1]);
    if(chdir("/tmp") != 0) _exit(126);
    execl(interp, interp, path, (char *)NULL);
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
        close(p[i].fd); p[i].fd = -1; done++;
      }
    }
  }
  for(int i = 0; i < 2; i++) if(p[i].fd >= 0) close(p[i].fd);
  int st = 0;
  waitpid(pid, &st, 0);
  *status = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
  return killed;
}

/* ---- result rendering ---- */

static int align_right(const duckdb::LogicalType &t){
  switch(t.id()){
    case duckdb::LogicalTypeId::TINYINT: case duckdb::LogicalTypeId::SMALLINT:
    case duckdb::LogicalTypeId::INTEGER: case duckdb::LogicalTypeId::BIGINT:
    case duckdb::LogicalTypeId::HUGEINT: case duckdb::LogicalTypeId::UTINYINT:
    case duckdb::LogicalTypeId::USMALLINT: case duckdb::LogicalTypeId::UINTEGER:
    case duckdb::LogicalTypeId::UBIGINT: case duckdb::LogicalTypeId::UHUGEINT:
    case duckdb::LogicalTypeId::FLOAT: case duckdb::LogicalTypeId::DOUBLE:
    case duckdb::LogicalTypeId::DECIMAL:
      return 1;
    default:
      return 0;
  }
}

static void render_result(sbuf *md, duckdb::MaterializedQueryResult &res){
  duckdb::idx_t nf = res.ColumnCount();
  if(nf == 0) return;
  sbuf h2 = {0};
  sb_puts(md, "|");
  sb_puts(&h2, "|");
  for(duckdb::idx_t i = 0; i < nf; i++){
    const std::string &name = res.names[i];
    int ar = align_right(res.types[i]);
    sb_putc(md, ' ');
    md_cell(md, name.data(), name.size());
    sb_puts(md, " |");
    sb_putc(&h2, ar ? '-' : ':');
    for(size_t j = 0; j < name.size(); j++) sb_putc(&h2, '-');
    sb_putc(&h2, ar ? ':' : '-');
    sb_putc(&h2, '|');
  }
  sb_putc(md, '\n');
  sb_putn(md, h2.s, h2.len);
  sb_putc(md, '\n');
  sb_free(&h2);
  duckdb::idx_t nr = res.RowCount();
  for(duckdb::idx_t r = 0; r < nr; r++){
    sb_puts(md, "|");
    for(duckdb::idx_t c = 0; c < nf; c++){
      sb_putc(md, ' ');
      duckdb::Value v = res.GetValue(c, r);
      if(v.IsNull()) sb_puts(md, "*null*");
      else {
        std::string s = v.ToString();
        md_cell(md, s.data(), s.size());
      }
      sb_puts(md, " |");
    }
    sb_putc(md, '\n');
  }
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

static const char *MEMLIMIT = "set memory_limit='600MB'";

int main(int argc, char **argv){
  const char *inpath = argc > 1 ? argv[1] : "/data/batches.json";
  const char *outpath = argc > 2 ? argv[2] : "/data/output.json";

  /* 15s, inside run.sh's 20s: a hung batch must not cost the whole body */
  long deadline = now_ms() + 15000;

  size_t blen = 0, nb = 0;
  char *btext = read_file(inpath, &blen);
  batch *batches = btext ? parse_payload(btext, &nb) : NULL;

  int any_lang = 0;
  for(size_t i = 0; i < nb; i++) if(batches[i].lang[0]) any_lang = 1;

  /* file-backed only when a language batch needs it: a SQL-only fiddle stays
     in-memory, so pragma database_list and the SQL corpus are unchanged */
  const char *dbpath = any_lang ? "/data/fiddle.duckdb" : NULL;
  std::unique_ptr<duckdb::DuckDB> db(new duckdb::DuckDB(dbpath));
  std::unique_ptr<duckdb::Connection> con(new duckdb::Connection(*db));
  /* headroom below the 1024MiB guest: allocation failures surface as SQL
     errors instead of the OOM killer taking the runner */
  con->Query(MEMLIMIT);

  sbuf out = {0};
  sb_putc(&out, '[');
  int reopen_failed = 0;
  for(size_t i = 0; i < nb; i++){
    sbuf md = {0};
    const char *lang = batches[i].lang;

    if(reopen_failed){
      const char *m = "not run: the database could not be reopened after a language batch";
      fence_block(&md, m, strlen(m), "error");
    } else if(!lang[0]){
      duckdb::vector<duckdb::unique_ptr<duckdb::SQLStatement>> stmts;
      bool parsed = true;
      try {
        stmts = con->ExtractStatements(std::string(batches[i].s, batches[i].len));
      } catch (std::exception &ex) {
        const char *err = ex.what();
        fence_block(&md, err, strlen(err), "error");
        parsed = false;
      }
      if(parsed) for(auto &stmt : stmts){
        auto res = con->Query(std::move(stmt));
        if(res->HasError()){
          const std::string &err = res->GetError();
          fence_block(&md, err.data(), err.size(), "error");
          break;
        }
        if(res->properties.return_type == duckdb::StatementReturnType::QUERY_RESULT){
          render_result(&md, (duckdb::MaterializedQueryResult &)*res);
          sb_putc(&md, '\n');
        }
      }
    } else {
      const char *interp = lang_interp(lang);
      if(!interp){
        sbuf m = {0};
        sb_puts(&m, "unknown language: ");
        sb_puts(&m, lang);
        fence_block(&md, m.s, m.len, "error");
        sb_free(&m);
      } else {
        sbuf so = {0}, se = {0};
        int status = 0, killed = 0, skipped = 0;
        if(now_ms() >= deadline) skipped = 1;
        else {
          /* duckdb locks the file exclusively: release it for the child, then reopen */
          if(dbpath){ con.reset(); db.reset(); }
          killed = run_batch(&batches[i], i, interp, lang_suffix(lang),
                             &so, &se, &status, deadline);
          if(dbpath){
            try {
              db.reset(new duckdb::DuckDB(dbpath));
              con.reset(new duckdb::Connection(*db));
              con->Query(MEMLIMIT);
            } catch (std::exception &ex) {
              /* a child killed mid-write can leave a file that will not replay: fence
                 the rest rather than die and return an empty body */
              reopen_failed = 1;
            }
          }
        }
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
    }
    if(i) sb_putc(&out, ',');
    json_emit_string(&out, md.s ? md.s : "", md.len);
    sb_free(&md);
  }
  sb_putc(&out, ']');

  FILE *f = fopen(outpath, "wb");
  if(!f) return 1;
  fwrite(out.s, 1, out.len, f);
  fclose(f);
  return 0;
}
EOC

# one version feeds libduckdb.so, the python wheel and the node binding: all three open
# the same file, so their storage formats must match
DUCKDB_VER=$(curl -sf https://api.github.com/repos/duckdb/duckdb/releases \
  | grep -o '"tag_name": "v1\.4\.[0-9]*"' | head -1 | grep -o 'v1\.4\.[0-9]*')
[ -n "$DUCKDB_VER" ] || { echo "ABORT: no v1.4.x duckdb release resolved"; exit 1; }

# the binding's `latest` tracks a newer duckdb line: take lts-v1.4, and gate on it
NODE_DUCKDB=$(curl -sf https://registry.npmjs.org/@duckdb%2fnode-api \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["dist-tags"]["lts-v1.4"])')
[ "${NODE_DUCKDB%%-r.*}" = "${DUCKDB_VER#v}" ] || {
  echo "ABORT: node binding $NODE_DUCKDB does not match libduckdb $DUCKDB_VER"; exit 1; }
echo "building against duckdb $DUCKDB_VER (node binding $NODE_DUCKDB)"

cat > /mnt/fire/duckdb_1.4/DOCKERFILE <<EOF
FROM node:26-trixie-slim
RUN apt-get update && apt-get install --no-install-recommends -y systemd-sysv udev haveged python3
RUN apt-get install --no-install-recommends -y python3-pip \\
  && pip install --break-system-packages --no-cache-dir duckdb==${DUCKDB_VER#v} \\
  && apt-get purge -y python3-pip && apt-get autoremove -y \\
  && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /opt/nb && cd /opt/nb \\
  && npm install --omit=dev --no-audit --no-fund @duckdb/node-api@${NODE_DUCKDB} \\
  && mv /opt/nb/node_modules /node_modules \\
  && cd / && rm -rf /opt/nb \\
  && npm cache clean --force
RUN echo '[Service]' > /etc/systemd/system/fiddle.service \\
  && echo 'ExecStart=/fiddle.sh' >> /etc/systemd/system/fiddle.service \\
  && echo '[Install]' >> /etc/systemd/system/fiddle.service \\
  && echo 'WantedBy=default.target' >> /etc/systemd/system/fiddle.service \\
  && systemctl enable fiddle
RUN echo "root:Docker!" | chpasswd
ENTRYPOINT ["bash"]
EOF

# per-engine tag: concurrent builds on cumbria2 must never share one
# fatal: a failed build leaves the previous image under the tag, and the populate step
# would silently tar it into the rootfs
DOCKER_BUILDKIT=1 docker build --no-cache -t duckdb_1.4 - < /mnt/fire/duckdb_1.4/DOCKERFILE \
  || { echo "ABORT: docker build failed"; exit 1; }
# 700 left 140M free after the ceremony
dd if=/dev/zero bs=1M count=635 > /mnt/fire/duckdb_1.4/rootfs.ext4
mkfs.ext4 -m 0 /mnt/fire/duckdb_1.4/rootfs.ext4
mount -o loop /mnt/fire/duckdb_1.4/rootfs.ext4 /mnt/fire/duckdb_1.4/mnt
cp /mnt/fire/duckdb_1.4/fiddle.cc /mnt/fire/duckdb_1.4/mnt/fiddle.cc
mkdir -p /mnt/fire/duckdb_1.4/libduckdb
curl -sfLo /mnt/fire/duckdb_1.4/libduckdb/libduckdb-linux-amd64.zip https://github.com/duckdb/duckdb/releases/download/$DUCKDB_VER/libduckdb-linux-amd64.zip
unzip -o -d /mnt/fire/duckdb_1.4/libduckdb /mnt/fire/duckdb_1.4/libduckdb/libduckdb-linux-amd64.zip
docker run --rm -v /mnt/fire/duckdb_1.4/libduckdb:/dd -v /mnt/fire/duckdb_1.4/mnt:/my-rootfs debian:trixie-slim bash -c 'apt-get update -qq && apt-get install -y -qq g++ && g++ -O2 -o /my-rootfs/fiddle /my-rootfs/fiddle.cc -I/dd -L/dd -lduckdb && mkdir -p /my-rootfs/usr/lib/x86_64-linux-gnu && cp /dd/libduckdb.so /my-rootfs/usr/lib/x86_64-linux-gnu/ && rm /my-rootfs/fiddle.cc'
docker run --rm -v /mnt/fire/duckdb_1.4/mnt:/my-rootfs duckdb_1.4 -c 'for d in bin etc home lib lib64 opt root sbin usr dev var node_modules; do tar c "/$d" | tar x -C /my-rootfs; done; for dir in run proc sys data; do mkdir /my-rootfs/$dir; done; mknod -m 666 /my-rootfs/dev/ttyS0 c 4 64; chroot /my-rootfs ldd /fiddle'

# the runner execs these paths: a wrong one fails every language batch and no SQL test notices
for p in usr/bin/python3 usr/local/bin/node; do
  [ -x /mnt/fire/duckdb_1.4/mnt/$p ] \
    || { echo "ABORT: /$p is missing from the rootfs"; exit 1; }
done

cp /mnt/fire/duckdb_1.4/vsock /mnt/fire/duckdb_1.4/mnt/vsock
chmod 755 /mnt/fire/duckdb_1.4/mnt/vsock

# any edit to fiddle.sh or /fiddle invalidates the snapshot: re-run the ceremony
cat <<"EOF" > /mnt/fire/duckdb_1.4/mnt/fiddle.sh
#!/bin/sh
dd if=/dev/random count=1 bs=1
echo '["select 1"]' > /data/warm.json
/fiddle /data/warm.json /data/warmout.json
echo '[["import duckdb\nprint(1)","python"]]' > /data/warm.json
/fiddle /data/warm.json /data/warmout.json
echo '[["require(\"@duckdb/node-api\");console.log(1)","node"]]' > /data/warm.json
/fiddle /data/warm.json /data/warmout.json
# the language warm-ups created the database file: left behind, every fiddle inherits it
rm -f /data/warm.json /data/warmout.json /data/fiddle.duckdb /tmp/batch*
sync
/vsock serve > /data/batches.json
/fiddle
/vsock reply < /data/output.json
reboot -ff
EOF

chmod 700 /mnt/fire/duckdb_1.4/mnt/fiddle.sh

umount /mnt/fire/duckdb_1.4/mnt

zfs set recordsize=16K tank/fire/duckdb_1.4
zfs set compression=lz4 tank/fire/duckdb_1.4

cd /mnt/fire/duckdb_1.4
rm -f mem vmstate v.sock* /tmp/fc-snap-duckdb_1.4.sock /tmp/fc-snap-duckdb_1.4.log
firecracker-1.13 --api-sock /tmp/fc-snap-duckdb_1.4.sock --config-file config.json > /tmp/fc-snap-duckdb_1.4.log 2>&1 &
for i in $(seq 300); do grep -q FIDDLE-READY /tmp/fc-snap-duckdb_1.4.log && break; sleep 0.1; done
grep -q FIDDLE-READY /tmp/fc-snap-duckdb_1.4.log || {
  echo "ABORT: guest never reached FIDDLE-READY - console log follows"
  tail -25 /tmp/fc-snap-duckdb_1.4.log; exit 1; }
sleep 0.3
curl -sf --unix-socket /tmp/fc-snap-duckdb_1.4.sock -X PATCH http://localhost/vm -H 'Content-Type: application/json' -d '{"state":"Paused"}'
curl -sf --unix-socket /tmp/fc-snap-duckdb_1.4.sock -X PUT http://localhost/snapshot/create -H 'Content-Type: application/json' -d '{"snapshot_type":"Full","snapshot_path":"vmstate","mem_file_path":"mem"}'
kill $! || true

zfs destroy tank/fire/duckdb_1.4@base 2>/dev/null || true
zfs snapshot tank/fire/duckdb_1.4@base

mkdir -p /mnt/fire/duckdb_1.4/hcheck
mount -o ro,norecovery,loop /mnt/fire/duckdb_1.4/rootfs.ext4 /mnt/fire/duckdb_1.4/hcheck
free=$(df -m --output=avail /mnt/fire/duckdb_1.4/hcheck | tail -1 | tr -d ' ')
umount /mnt/fire/duckdb_1.4/hcheck
rmdir /mnt/fire/duckdb_1.4/hcheck
echo "post-ceremony free space: ${free}M (target 50-100M)"
[ "$free" -ge 40 ] || { echo "ABORT: only ${free}M free, raise the dd count"; exit 1; }

out=$(echo '["select version()"]' | /mnt/fire/duckdb_1.4/run.sh) || true
printf '%s\n' "$out"
# run.sh has no meaningful exit status: assert on the body
[ -n "$out" ] || { echo "ABORT: verification fiddle returned an empty body"; exit 1; }

cat > /tmp/duckdb_1.4-langcheck.json <<'EOF'
[["create table t as select 42 x",""],
 ["import duckdb\nc = duckdb.connect('/data/fiddle.duckdb')\nprint('py-sees:' + str(c.sql('select * from t').fetchone()[0]))","python"],
 ["const { DuckDBInstance } = require('@duckdb/node-api');\n(async () => {\n  const i = await DuckDBInstance.create('/data/fiddle.duckdb');\n  const c = await i.connect();\n  const r = await c.runAndReadAll('select * from t');\n  console.log('node-sees:' + r.getRows()[0][0]);\n})();","node"]]
EOF
lang=$(/mnt/fire/duckdb_1.4/run.sh < /tmp/duckdb_1.4-langcheck.json) || true
printf '%s\n' "$lang"
case $lang in *py-sees:42*) ;;
  *) echo "ABORT: the python batch did not read the shared database"; exit 1 ;;
esac
case $lang in *node-sees:42*) ;;
  *) echo "ABORT: the node batch did not read the shared database"; exit 1 ;;
esac
