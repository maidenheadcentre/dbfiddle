echo 'www-data        ALL=(ALL) NOPASSWD: /mnt/fire/redis_8.10/run.sh' >> /etc/sudoers
zfs create tank/fire/redis_8.10
cp /mnt/fire/vmlinux-5.10.223 /mnt/fire/redis_8.10/vmlinux.bin

<<'EOF' cat > /mnt/fire/redis_8.10/config.json
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

<<'EOF' cat > /mnt/fire/redis_8.10/vsock.c
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
gcc -O2 -static -o /mnt/fire/redis_8.10/vsock /mnt/fire/redis_8.10/vsock.c

# never write listener.pl here: /mnt/fire/listener.pl is shared by every engine

<<'EOF' cat > /mnt/fire/redis_8.10/run.sh
#!/bin/bash
# never pass "$@" through: the sudoers line has no argument spec, so any argument is
# permitted and the caller would be choosing the engine
exec /mnt/fire/run.sh "$(basename "$(dirname "$(readlink -f "$0")")")"
EOF

chmod 700 /mnt/fire/redis_8.10/run.sh

mkdir /mnt/fire/redis_8.10/mnt
<<'EOC' cat > /mnt/fire/redis_8.10/fiddle.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <sys/wait.h>

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

/* lang is "" for the cli; never NULL */
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

/* ---- batches ---- */

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

/* the cli's own defaults, 127.0.0.1:6379 and RESP2. --no-raw keeps the (error), (integer)
   and (nil) markers it drops when stdout is not a terminal */
static char *const CLI[] = { (char *)"/usr/local/bin/redis-cli", (char *)"--no-raw", NULL };

static const char *lang_interp(const char *lang){
  if(!strcmp(lang, "python")) return "/usr/bin/python3";
  if(!strcmp(lang, "node")) return "/usr/local/bin/node";
  if(!strcmp(lang, "php")) return "/usr/bin/php";
  return NULL;
}
static const char *lang_suffix(const char *lang){
  return !strcmp(lang, "python") ? "py" : !strcmp(lang, "node") ? "js" : "php";
}

/* in is written as the child reads it, never all up front: a long batch with a long reply
   would fill both pipes and deadlock. Without in, stdin is /dev/null, or a batch that
   reads it blocks until the deadline */
static int run_child(char *const *av, const char *in, size_t inlen,
                     sbuf *so, sbuf *se, int *status, long deadline){
  int ip[2] = { -1, -1 }, op[2], ep[2];
  if(in && pipe(ip) < 0) return 0;
  if(pipe(op) < 0 || pipe(ep) < 0) return 0;

  pid_t pid = fork();
  if(pid < 0) return 0;
  if(pid == 0){
    signal(SIGPIPE, SIG_DFL);
    int src = in ? ip[0] : open("/dev/null", O_RDONLY);
    dup2(src, 0); dup2(op[1], 1); dup2(ep[1], 2);
    if(in){ close(ip[0]); close(ip[1]); }
    close(op[0]); close(op[1]); close(ep[0]); close(ep[1]);
    if(chdir("/tmp") != 0) _exit(126);
    execv(av[0], av);
    _exit(127);
  }
  close(op[1]); close(ep[1]);
  if(in){
    close(ip[0]);
    fcntl(ip[1], F_SETFL, O_NONBLOCK);
  }

  size_t off = 0;
  int done = 0, killed = 0;
  struct pollfd p[3] = { { op[0], POLLIN, 0 }, { ep[0], POLLIN, 0 }, { ip[1], POLLOUT, 0 } };
  if(p[2].fd >= 0 && !inlen){ close(p[2].fd); p[2].fd = -1; }
  while(done < 2){
    long left = deadline - now_ms();
    if(left <= 0){ kill(pid, SIGKILL); killed = 1; break; }
    int r = poll(p, 3, left > 200 ? 200 : (int)left);
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
    if(p[2].fd >= 0 && p[2].revents){
      ssize_t w = write(p[2].fd, in + off, inlen - off);
      if(w > 0) off += (size_t)w;
      if((w < 0 && errno != EAGAIN) || off == inlen){ close(p[2].fd); p[2].fd = -1; }
    }
  }
  for(int i = 0; i < 3; i++) if(p[i].fd >= 0) close(p[i].fd);
  int st = 0;
  waitpid(pid, &st, 0);
  *status = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
  return killed;
}

/* a plain batch is a cli session fed on stdin, a language batch a file its interpreter runs */
static void run_batch(sbuf *md, const batch *b, size_t idx, long deadline){
  const char *lang = b->lang;
  char path[64];
  char *av[3] = { NULL, path, NULL };
  if(lang[0] && !(av[0] = (char *)lang_interp(lang))){
    sbuf m = {0};
    sb_puts(&m, "unknown language: ");
    sb_puts(&m, lang);
    fence_block(md, m.s, m.len, "error");
    sb_free(&m);
    return;
  }
  if(now_ms() >= deadline){
    const char *m = "not run: an earlier batch used the runner's time budget";
    fence_block(md, m, strlen(m), "error");
    return;
  }
  sbuf so = {0}, se = {0};
  int status = 0, killed;
  if(lang[0]){
    snprintf(path, sizeof path, "/tmp/batch%zu.%s", idx + 1, lang_suffix(lang));
    FILE *f = fopen(path, "wb");
    if(f){ fwrite(b->s, 1, b->len, f); fclose(f); }
    killed = run_child(av, NULL, 0, &so, &se, &status, deadline);
  } else {
    killed = run_child(CLI, b->s, b->len, &so, &se, &status, deadline);
  }
  if(so.len) fence_plain(md, so.s, so.len, "");
  if(se.len) fence_block(md, se.s, se.len, "error");
  if(killed){
    const char *m = "batch did not finish within the runner's time budget";
    fence_block(md, m, strlen(m), "error");
  } else if(status != 0 && !se.len){
    char m[64];
    int n = snprintf(m, sizeof m, "exited with status %d", status);
    fence_block(md, m, (size_t)n, "error");
  }
  sb_free(&so);
  sb_free(&se);
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

  /* 15s, inside run.sh's 20s: a hung batch must not cost the whole body */
  long deadline = now_ms() + 15000;

  /* a child that exits with its batch unread must not take the runner with it */
  signal(SIGPIPE, SIG_IGN);

  size_t blen = 0, nb = 0;
  char *btext = read_file(inpath, &blen);
  batch *batches = btext ? parse_payload(btext, &nb) : NULL;

  sbuf out = {0};
  sb_putc(&out, '[');
  for(size_t i = 0; i < nb; i++){
    sbuf md = {0};
    run_batch(&md, &batches[i], i, deadline);
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

# RediSearch's thread pool calls srand(time(NULL)) as it loads, replacing the server's seed
# with the whole second: every fiddle started in the same second would share SRANDMEMBER
<<'EOC' cat > /mnt/fire/redis_8.10/srand.c
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/random.h>

void srand(unsigned seed){
  unsigned r = 0;
  getrandom(&r, sizeof r, 0);
  ((void (*)(unsigned))dlsym(RTLD_NEXT, "srand"))(seed ^ r);
}
EOC

cat > /mnt/fire/redis_8.10/DOCKERFILE <<'EOF'
FROM node:26-trixie-slim AS js
RUN mkdir /opt/nb && cd /opt/nb && npm install --omit=dev --no-audit --no-fund redis

FROM redis:8.10-trixie
RUN apt-get update && apt-get install --no-install-recommends -y systemd-sysv udev haveged libatomic1 python3 python3-pip php-cli php-redis \
  && pip install --break-system-packages --no-cache-dir redis \
  && apt-get purge -y python3-pip && apt-get autoremove -y \
  && rm -rf /var/lib/apt/lists/*
COPY --from=js /usr/local/bin/node /usr/local/bin/node
COPY --from=js /opt/nb/node_modules /node_modules
RUN echo '[Service]' > /etc/systemd/system/fiddle.service \
  && echo 'ExecStart=/fiddle.sh' >> /etc/systemd/system/fiddle.service \
  && echo '[Install]' >> /etc/systemd/system/fiddle.service \
  && echo 'WantedBy=default.target' >> /etc/systemd/system/fiddle.service \
  && systemctl enable fiddle
RUN echo "root:Docker!" | chpasswd
ENTRYPOINT ["bash"]
EOF

# per-engine tags: concurrent builds on cumbria2 must never share one
# fatal: a failed build leaves the previous image under the tag, and the populate step
# would silently tar it into the rootfs
DOCKER_BUILDKIT=1 docker build --no-cache -t redis_8.10 - < /mnt/fire/redis_8.10/DOCKERFILE \
  || { echo "ABORT: docker build failed"; exit 1; }
REDIS_VER=$(docker run --rm redis_8.10 -c 'redis-server --version' | grep -o 'v=8\.10\.[0-9]*' | cut -c3-)
[ -n "$REDIS_VER" ] || { echo "ABORT: the image's redis-server is not 8.10.x"; exit 1; }
echo "building redis $REDIS_VER"
# du 411M + ~28M ext4 overhead + a 75M target
dd if=/dev/zero bs=1M count=515 > /mnt/fire/redis_8.10/rootfs.ext4
mkfs.ext4 -m 0 /mnt/fire/redis_8.10/rootfs.ext4
mount -o loop /mnt/fire/redis_8.10/rootfs.ext4 /mnt/fire/redis_8.10/mnt
cp /mnt/fire/redis_8.10/fiddle.c /mnt/fire/redis_8.10/srand.c /mnt/fire/redis_8.10/mnt/
docker run --rm -v /mnt/fire/redis_8.10/mnt:/my-rootfs debian:trixie-slim bash -c 'apt-get update -qq && apt-get install -y -qq gcc && gcc -O2 -Wall -o /my-rootfs/fiddle /my-rootfs/fiddle.c && gcc -O2 -Wall -shared -fPIC -o /my-rootfs/srand.so /my-rootfs/srand.c && rm /my-rootfs/fiddle.c /my-rootfs/srand.c'
[ -x /mnt/fire/redis_8.10/mnt/fiddle ] || { echo "ABORT: the runner did not compile"; exit 1; }
[ -f /mnt/fire/redis_8.10/mnt/srand.so ] || { echo "ABORT: the srand shim did not compile"; exit 1; }
docker run --rm -v /mnt/fire/redis_8.10/mnt:/my-rootfs redis_8.10 -c 'for d in bin etc home lib lib64 opt root sbin usr dev var node_modules; do tar c "/$d" | tar x -C /my-rootfs; done; for dir in run proc sys data; do mkdir /my-rootfs/$dir; done; mknod -m 666 /my-rootfs/dev/ttyS0 c 4 64; chroot /my-rootfs ldd /fiddle'
docker rmi redis_8.10

# the runner execs these paths: a wrong one fails every batch of its kind and nothing else notices
for p in usr/local/bin/redis-cli usr/local/bin/redis-server usr/local/bin/docker-entrypoint.sh usr/bin/python3 usr/local/bin/node usr/bin/php; do
  [ -x /mnt/fire/redis_8.10/mnt/$p ] \
    || { echo "ABORT: /$p is missing from the rootfs"; exit 1; }
done
# 2>&1: a startup warning, such as an extension that failed to load, must fail the comparison
clients=$(chroot /mnt/fire/redis_8.10/mnt /bin/sh -c 'python3 -c "import redis; print(\"python\")"; node -e "require(\"redis\"); console.log(\"node\")"; php -r "new Redis(); echo \"php\n\";"' 2>&1 || true)
[ "$clients" = "$(printf 'python\nnode\nphp')" ] || { echo "ABORT: a client library did not load: $clients"; exit 1; }

cp /mnt/fire/redis_8.10/vsock /mnt/fire/redis_8.10/mnt/vsock
chmod 755 /mnt/fire/redis_8.10/mnt/vsock

# any edit to fiddle.sh or /fiddle invalidates the snapshot: re-run the ceremony
cat <<"EOF" > /mnt/fire/redis_8.10/mnt/fiddle.sh
#!/bin/sh
dd if=/dev/random count=1 bs=1
cd /data
# this server only warms the page cache: one started before the snapshot would freeze its
# PRNG and hash seed into mem, and every fiddle would share them
LD_PRELOAD=/srand.so docker-entrypoint.sh redis-server &
until grep -q ':18EB 00000000:0000 0A' /proc/net/tcp ; do : ; done
# printf, not echo: this is dash, and its echo would turn the \n into a newline
printf '%s\n' '["PING"]' > /tmp/warm.json
printf 'warm-up: %s\n' "$(/fiddle /tmp/warm.json /tmp/warmout.json >/dev/null 2>&1; cat /tmp/warmout.json)" > /dev/console 2>&1
printf '%s\n' '[["import redis\nprint(redis.Redis().ping())","python"]]' > /tmp/warm.json
printf 'warm-up python: %s\n' "$(/fiddle /tmp/warm.json /tmp/warmout.json >/dev/null 2>&1; cat /tmp/warmout.json)" > /dev/console 2>&1
printf '%s\n' '[["const { createClient } = require(\"redis\");\ncreateClient().connect().then(async c => { console.log(await c.ping()); await c.close(); });","node"]]' > /tmp/warm.json
printf 'warm-up node: %s\n' "$(/fiddle /tmp/warm.json /tmp/warmout.json >/dev/null 2>&1; cat /tmp/warmout.json)" > /dev/console 2>&1
printf '%s\n' '[["<?php\n$r = new Redis();\n$r->connect(\"127.0.0.1\");\necho $r->ping(\"pong-php\");","php"]]' > /tmp/warm.json
printf 'warm-up php: %s\n' "$(/fiddle /tmp/warm.json /tmp/warmout.json >/dev/null 2>&1; cat /tmp/warmout.json)" > /dev/console 2>&1
redis-cli shutdown nosave
wait
rm -f /tmp/warm.json /tmp/warmout.json /tmp/batch*
sync
/vsock serve > /tmp/batches.json
LD_PRELOAD=/srand.so docker-entrypoint.sh redis-server &
# the listening socket, never a ping: every connection takes a client id, and CLIENT ID
# would then differ from fiddle to fiddle
until grep -q ':18EB 00000000:0000 0A' /proc/net/tcp ; do : ; done
/fiddle
/vsock reply < /tmp/output.json
reboot -ff
EOF

chmod 700 /mnt/fire/redis_8.10/mnt/fiddle.sh

umount /mnt/fire/redis_8.10/mnt

zfs set recordsize=16K tank/fire/redis_8.10
zfs set compression=lz4 tank/fire/redis_8.10

cd /mnt/fire/redis_8.10
rm -f mem vmstate v.sock* /tmp/fc-snap-redis_8.10.sock /tmp/fc-snap-redis_8.10.log
firecracker-1.13 --api-sock /tmp/fc-snap-redis_8.10.sock --config-file config.json > /tmp/fc-snap-redis_8.10.log 2>&1 &
for i in $(seq 300); do grep -q FIDDLE-READY /tmp/fc-snap-redis_8.10.log && break; sleep 0.1; done
grep -q FIDDLE-READY /tmp/fc-snap-redis_8.10.log || {
  echo "ABORT: guest never reached FIDDLE-READY - console log follows"
  tail -25 /tmp/fc-snap-redis_8.10.log; exit 1; }
# the warm-ups are the only proof that the runner and each client work inside the guest
for w in ': .*PONG' ' python: .*True' ' node: .*PONG' ' php: .*pong-php'; do
  grep -a "warm-up$w" /tmp/fc-snap-redis_8.10.log || {
    echo "ABORT: no 'warm-up$w' on the console - console log follows"
    tail -25 /tmp/fc-snap-redis_8.10.log; kill $!; exit 1; }
done
sleep 0.3
curl -sf --unix-socket /tmp/fc-snap-redis_8.10.sock -X PATCH http://localhost/vm -H 'Content-Type: application/json' -d '{"state":"Paused"}'
curl -sf --unix-socket /tmp/fc-snap-redis_8.10.sock -X PUT http://localhost/snapshot/create -H 'Content-Type: application/json' -d '{"snapshot_type":"Full","snapshot_path":"vmstate","mem_file_path":"mem"}'
kill $! || true

zfs destroy tank/fire/redis_8.10@base 2>/dev/null || true
zfs snapshot tank/fire/redis_8.10@base

mkdir -p /mnt/fire/redis_8.10/hcheck
mount -o ro,norecovery,loop /mnt/fire/redis_8.10/rootfs.ext4 /mnt/fire/redis_8.10/hcheck
free=$(df -m --output=avail /mnt/fire/redis_8.10/hcheck | tail -1 | tr -d ' ')
umount /mnt/fire/redis_8.10/hcheck
rmdir /mnt/fire/redis_8.10/hcheck
echo "post-ceremony free space: ${free}M (target 50-100M)"
[ "$free" -ge 50 ] && [ "$free" -le 100 ] || { echo "ABORT: ${free}M free, re-derive the dd count"; exit 1; }

out=$(echo '["HELLO"]' | /mnt/fire/redis_8.10/run.sh) || true
printf '%s\n' "$out"
# run.sh has no meaningful exit status: assert on the body
[ -n "$out" ] || { echo "ABORT: verification fiddle returned an empty body"; exit 1; }
case $out in *"$REDIS_VER"*) ;;
  *) echo "ABORT: the engine does not report $REDIS_VER"; exit 1 ;;
esac

# the entrypoint loads the bundled modules: a server started any other way has none
cat > /tmp/redis_8.10-modcheck.json <<'EOF'
["JSON.SET d $ '{\"a\":[1,2]}'\nJSON.GET d $.a[1]\nTS.ADD t 1 5\nBF.ADD b x\nFT.CREATE i SCHEMA n TEXT"]
EOF
mods=$(/mnt/fire/redis_8.10/run.sh < /tmp/redis_8.10-modcheck.json) || true
printf '%s\n' "$mods"
case $mods in *'\"[2]\"\n(integer) 1\n(integer) 1\nOK'*) ;;
  *) echo "ABORT: the json, timeseries, bloom and search modules did not all answer"; exit 1 ;;
esac

cat > /tmp/redis_8.10-shimcheck.json <<'EOF'
[["import glob\nfor c in glob.glob('/proc/[0-9]*/comm'):\n    if open(c).read().strip() == 'redis-server':\n        print('shim:', '/srand.so' in open(c[:-4] + 'maps').read())","python"]]
EOF
shim=$(/mnt/fire/redis_8.10/run.sh < /tmp/redis_8.10-shimcheck.json) || true
printf '%s\n' "$shim"
case $shim in *'shim: True\n```'*) ;;
  *) echo "ABORT: redis-server did not load /srand.so"; exit 1 ;;
esac

cat > /tmp/redis_8.10-langcheck.json <<'EOF'
[["SET answer 42",""],
 ["import redis\nprint('py-sees:' + redis.Redis().get('answer').decode())","python"],
 ["const { createClient } = require('redis');\n(async () => {\n  const c = await createClient().connect();\n  console.log('node-sees:' + await c.get('answer'));\n  await c.close();\n})();","node"],
 ["<?php\n$r = new Redis();\n$r->connect('127.0.0.1');\necho 'php-sees:', $r->get('answer');\n$r->set('answer', 43);","php"],
 ["GET answer",""],
 ["<?php\nexit(4);","php"]]
EOF
lang=$(/mnt/fire/redis_8.10/run.sh < /tmp/redis_8.10-langcheck.json) || true
printf '%s\n' "$lang"
case $lang in *py-sees:42*) ;;
  *) echo "ABORT: the python batch did not read what the cli wrote"; exit 1 ;;
esac
case $lang in *node-sees:42*) ;;
  *) echo "ABORT: the node batch did not read what the cli wrote"; exit 1 ;;
esac
case $lang in *php-sees:42*) ;;
  *) echo "ABORT: the php batch did not read what the cli wrote"; exit 1 ;;
esac
case $lang in *'\"43\"'*) ;;
  *) echo "ABORT: the php write is not visible to the next cli batch"; exit 1 ;;
esac
case $lang in *'exited with status 4'*) ;;
  *) echo "ABORT: a non-zero php exit was not reported"; exit 1 ;;
esac
