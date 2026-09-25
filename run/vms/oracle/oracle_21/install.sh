echo 'www-data        ALL=(ALL) NOPASSWD: /mnt/fire/oracle_21/run.sh' >> /etc/sudoers
zfs create tank/fire/oracle_21
cp /mnt/fire/vmlinux-6.1.141 /mnt/fire/oracle_21/vmlinux.bin

# no-kvmapf: a task asleep on an async page fault at snapshot time never wakes after restore
<<'EOF' cat > /mnt/fire/oracle_21/config.json
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

<<'EOF' cat > /mnt/fire/oracle_21/vsock.c
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
gcc -O2 -static -o /mnt/fire/oracle_21/vsock /mnt/fire/oracle_21/vsock.c

# never write listener.pl here: /mnt/fire/listener.pl is shared by every engine

<<'EOF' cat > /mnt/fire/oracle_21/run.sh
#!/bin/bash
# never pass "$@" through: the sudoers line has no argument spec, so any argument is
# permitted and the caller would be choosing the engine
exec /mnt/fire/run.sh "$(basename "$(dirname "$(readlink -f "$0")")")"
EOF

chmod 700 /mnt/fire/oracle_21/run.sh

mkdir /mnt/fire/oracle_21/mnt

cat > /mnt/fire/oracle_21/DOCKERFILE <<"EOF"
FROM oraclelinux:8
RUN dnf -y install systemd oracle-database-preinstall-21c cronie tmux util-linux perl-interpreter hostname
RUN dnf -y install oracle-epel-release-el8 && dnf -y install haveged
# gcc stays: the runner is compiled in a chroot of this rootfs further down
RUN dnf -y install make gcc
RUN curl -fLo /tmp/oracle-xe.rpm https://download.oracle.com/otn-pub/otn_software/db-express/oracle-database-xe-21c-1.0-1.ol8.x86_64.rpm \
  && ORACLE_DOCKER_INSTALL=true dnf -y localinstall /tmp/oracle-xe.rpm \
  && rm /tmp/oracle-xe.rpm
RUN echo /opt/oracle/product/21c/dbhomeXE/lib > /etc/ld.so.conf.d/oracle.conf && ldconfig
RUN echo '[Service]' > /etc/systemd/system/fiddle.service \
  && echo 'ExecStart=/fiddle.sh' >> /etc/systemd/system/fiddle.service \
  && echo '[Install]' >> /etc/systemd/system/fiddle.service \
  && echo 'WantedBy=default.target' >> /etc/systemd/system/fiddle.service \
  && systemctl enable fiddle
RUN systemctl disable getty@tty1.service \
  && echo ttyS0 > /etc/securetty \
  && echo '[Service]' > /etc/systemd/system/mygetty.service \
  && echo 'ExecStart=/usr/sbin/agetty -L 9600 ttyS0 vt102' >> /etc/systemd/system/mygetty.service \
  && echo '[Install]' >> /etc/systemd/system/mygetty.service \
  && echo 'WantedBy=default.target' >> /etc/systemd/system/mygetty.service \
  && systemctl enable mygetty
RUN dnf clean all
RUN echo "root:Docker!" | chpasswd
ENTRYPOINT ["bash"]
EOF

DOCKER_BUILDKIT=1 docker build --no-cache -t dummy_oracle_21 - < /mnt/fire/oracle_21/DOCKERFILE
dd if=/dev/zero bs=1M count=18432 > /mnt/fire/oracle_21/rootfs.ext4
mkfs.ext4 /mnt/fire/oracle_21/rootfs.ext4
mount -o loop /mnt/fire/oracle_21/rootfs.ext4 /mnt/fire/oracle_21/mnt
# --hostname is baked into listener.ora and tnsnames.ora: it must match the guest's /etc/hosts
docker run --rm -ti --hostname fiddle --shm-size 2g -v /mnt/fire/oracle_21/mnt:/my-rootfs dummy_oracle_21
(echo wXYyXLlDVZB0ss2F; echo wXYyXLlDVZB0ss2F) | /etc/init.d/oracle-xe-21c configure
export ORACLE_HOME=/opt/oracle/product/21c/dbhomeXE ORACLE_SID=XE
$ORACLE_HOME/bin/sqlplus sys/wXYyXLlDVZB0ss2F@//localhost:1521/XE as sysdba <<"SQL"
alter pluggable database xepdb1 save state;
exit
SQL
$ORACLE_HOME/bin/sqlplus sys/wXYyXLlDVZB0ss2F@//localhost:1521/xepdb1 as sysdba <<"SQL"
alter profile default limit password_life_time unlimited;
create user fiddle identified by IIGjTTbsEzh64McU;
grant dba to fiddle with admin option;
grant select on v_$session to fiddle with grant option;
grant select on v_$sql_plan_statistics_all to fiddle with grant option;
grant select on v_$sql_plan to fiddle with grant option;
grant select on v_$sql to fiddle with grant option;
grant execute on dbms_session to fiddle with grant option;
exit
SQL
$ORACLE_HOME/bin/sqlplus fiddle/IIGjTTbsEzh64McU@//localhost:1521/xepdb1 <<"SQL"
create or replace function dbmsoutput return varchar as
  line varchar(32767);
  status number;
  ret varchar(32767);
begin
  loop
    dbms_output.get_line(line,status);
    if status = 0 then
      ret := (case when ret is null then line else ret||chr(10)||line end);
    else
      exit;
    end if;
  end loop;
  return ret;
end;
/
exit
SQL
/etc/init.d/oracle-xe-21c stop
for d in bin etc home lib lib64 opt root sbin usr dev run var; do tar c "/$d" | tar x -C /my-rootfs; done
for dir in proc sys data; do mkdir /my-rootfs/${dir}; done
mknod -m 666 /my-rootfs/dev/ttyS0 c 4 64
exit

# replace docker's bind-mounted network identity with the guest's offline one
printf '127.0.0.1 localhost fiddle\n::1 localhost\n' > /mnt/fire/oracle_21/mnt/etc/hosts
echo fiddle > /mnt/fire/oracle_21/mnt/etc/hostname
rm -f /mnt/fire/oracle_21/mnt/etc/systemd/system/multi-user.target.wants/oracle-xe-21c.service

# any edit to fiddle.sh or /fiddle invalidates the snapshot: re-run the ceremony
cat <<"EOF" > /mnt/fire/oracle_21/mnt/fiddle.sh
#!/bin/sh
dd if=/dev/random count=1 bs=1
export ORACLE_HOME=/opt/oracle/product/21c/dbhomeXE ORACLE_SID=XE
runuser -u oracle -- $ORACLE_HOME/bin/lsnrctl start
echo FIDDLE-LSNR > /dev/console
echo startup | runuser -u oracle -- $ORACLE_HOME/bin/sqlplus -s / as sysdba > /dev/console 2>&1
until echo "select open_mode from v\$pdbs where name='XEPDB1';" | runuser -u oracle -- $ORACLE_HOME/bin/sqlplus -s / as sysdba | grep -q 'READ WRITE' ; do sleep 0.5 ; done
/fiddle --warmup > /dev/console 2>&1
echo FIDDLE-WARMED > /dev/console
sync
/vsock serve > /tmp/batches.json
/fiddle
/vsock reply < /tmp/output.json
reboot -ff
EOF

chmod 700 /mnt/fire/oracle_21/mnt/fiddle.sh

<<'EOP' cat > /mnt/fire/oracle_21/mnt/probe.c
/* build-time only. OCIEnvCreate needs ORACLE_HOME for its NLS data, but no database */
#include <stdio.h>
#include <oci.h>
int main(void){
  OCIEnv *e = NULL;
  if(OCIEnvCreate(&e, OCI_DEFAULT, NULL, NULL, NULL, NULL, 0, NULL) != OCI_SUCCESS) return 1;
  printf("%u\n", (unsigned)OCINlsCharSetNameToId(e, (const oratext *)"AL32UTF8"));
  OCIHandleFree(e, OCI_HTYPE_ENV);
  return 0;
}
EOP
<<'EOC' cat > /mnt/fire/oracle_21/mnt/fiddle.c
/* shared across the oracle family apart from the connect string and 11.2, 18 and 21's
 * seed_random(): carry a change to every copy.
 * quirk kept: a BLOB renders through md_cell as text; only RAW and LONG RAW render as 0x...
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <oci.h>

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

/* ---- oci ---- */

#define LOB_CAP (64u * 1024 * 1024)

static OCIEnv *env;
static OCIError *err;
static OCISvcCtx *svc;

static void oci_msg(sbuf *b, void *h, ub4 htype){
  sb4 code = 0;
  text buf[3072];
  buf[0] = 0;
  OCIErrorGet(h, 1, NULL, &code, buf, (ub4)sizeof buf, htype);
  size_t n = strlen((char *)buf);
  while(n && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) n--;
  sb_putn(b, (char *)buf, n);
}

typedef struct {
  char *name;
  ub4 namelen;
  ub2 dtype;
  int is_raw, is_num, is_lob;
  char *buf;
  ub4 bufsz;
  OCILobLocator *lob;
  ub1 csform;
  sb2 ind;
  ub2 rlen;
} col;

static ub4 buffer_for(ub2 dtype, ub2 dsize){
  switch(dtype){
    case SQLT_NUM: case SQLT_INT: case SQLT_FLT:
    case SQLT_IBFLOAT: case SQLT_IBDOUBLE:
      return 128;
    case SQLT_DAT: case SQLT_TIMESTAMP: case SQLT_TIMESTAMP_TZ:
    case SQLT_TIMESTAMP_LTZ: case SQLT_INTERVAL_YM: case SQLT_INTERVAL_DS:
      return 256;
    case SQLT_LNG: case SQLT_LBI:
      return 65535;
    default: {
      ub4 n = (ub4)dsize * 4 + 8;
      if(n < 512) n = 512;
      if(n > 65535) n = 65535;
      return n;
    }
  }
}

static void hex_upper(sbuf *md, const unsigned char *p, size_t n){
  static const char h[] = "0123456789ABCDEF";
  sb_puts(md, "0x");
  for(size_t i = 0; i < n; i++){ sb_putc(md, h[p[i] >> 4]); sb_putc(md, h[p[i] & 15]); }
}

/* CLOB length is in characters */
static char *lob_read(OCILobLocator *lob, int is_blob, ub1 csform, size_t *out_n){
  oraub8 len = 0;
  *out_n = 0;
  if(OCILobGetLength2(svc, err, lob, &len) != OCI_SUCCESS || !len) return NULL;
  oraub8 want = len;
  if(want > LOB_CAP) want = LOB_CAP;
  size_t cap = is_blob ? (size_t)want : (size_t)want * 4 + 1;
  char *buf = malloc(cap + 1);
  if(!buf) oom();
  oraub8 byte_amt = is_blob ? want : 0;
  oraub8 char_amt = is_blob ? 0 : want;
  sword rc = OCILobRead2(svc, err, lob, &byte_amt, &char_amt, 1,
                         buf, (oraub8)cap, OCI_ONE_PIECE, NULL, NULL, 0, csform);
  if(rc != OCI_SUCCESS && rc != OCI_SUCCESS_WITH_INFO){ free(buf); return NULL; }
  buf[byte_amt] = 0;
  *out_n = (size_t)byte_amt;
  return buf;
}

static void render_result(sbuf *md, OCIStmt *stmt, ub4 nf){
  col *c = calloc(nf, sizeof *c);
  if(!c) oom();
  int undefinable = 0;

  for(ub4 i = 0; i < nf; i++){
    OCIParam *p = NULL;
    if(OCIParamGet(stmt, OCI_HTYPE_STMT, err, (void **)&p, i + 1) != OCI_SUCCESS) continue;
    text *nm = NULL; ub4 nmlen = 0; ub2 dsize = 0;
    OCIAttrGet(p, OCI_DTYPE_PARAM, &c[i].dtype, NULL, OCI_ATTR_DATA_TYPE, err);
    OCIAttrGet(p, OCI_DTYPE_PARAM, &nm, &nmlen, OCI_ATTR_NAME, err);
    OCIAttrGet(p, OCI_DTYPE_PARAM, &dsize, NULL, OCI_ATTR_DATA_SIZE, err);
    c[i].csform = SQLCS_IMPLICIT;
    OCIAttrGet(p, OCI_DTYPE_PARAM, &c[i].csform, NULL, OCI_ATTR_CHARSET_FORM, err);
    c[i].name = malloc(nmlen + 1);
    if(!c[i].name) oom();
    memcpy(c[i].name, nm, nmlen);
    c[i].name[nmlen] = 0;
    c[i].namelen = nmlen;
    c[i].is_num = c[i].dtype == SQLT_NUM;
    c[i].is_raw = c[i].dtype == SQLT_BIN || c[i].dtype == SQLT_LBI;
    c[i].is_lob = c[i].dtype == SQLT_CLOB || c[i].dtype == SQLT_BLOB;
    OCIDescriptorFree(p, OCI_DTYPE_PARAM);
    /* no string form: header, no rows. Never add SQLT_NTY - xmltype converts to SQLT_STR,
       and a collection is caught by the define failing below. */
    if(c[i].dtype == SQLT_REF || c[i].dtype == SQLT_RSET
       || c[i].dtype == SQLT_BFILE){
      undefinable = 1;
      continue;
    }

    OCIDefine *dfn = NULL;
    if(c[i].is_lob){
      OCIDescriptorAlloc(env, (void **)&c[i].lob, OCI_DTYPE_LOB, 0, NULL);
      if(OCIDefineByPos(stmt, &dfn, err, i + 1, &c[i].lob, (sb4)-1, c[i].dtype,
                        &c[i].ind, NULL, NULL, OCI_DEFAULT) != OCI_SUCCESS) undefinable = 1;
    } else {
      c[i].bufsz = buffer_for(c[i].dtype, dsize);
      c[i].buf = malloc(c[i].bufsz + 1);
      if(!c[i].buf) oom();
      if(OCIDefineByPos(stmt, &dfn, err, i + 1, c[i].buf, (sb4)c[i].bufsz,
                        c[i].is_raw ? SQLT_BIN : SQLT_STR,
                        &c[i].ind, &c[i].rlen, NULL, OCI_DEFAULT) != OCI_SUCCESS) undefinable = 1;
    }
  }

  sbuf h2 = {0};
  sb_puts(md, "|");
  sb_puts(&h2, "|");
  for(ub4 i = 0; i < nf; i++){
    sb_putc(md, ' ');
    md_cell(md, c[i].name, c[i].namelen);
    sb_puts(md, " |");
    sb_putc(&h2, c[i].is_num ? '-' : ':');
    for(ub4 j = 0; j < c[i].namelen; j++) sb_putc(&h2, '-');
    sb_putc(&h2, c[i].is_num ? ':' : '-');
    sb_putc(&h2, '|');
  }
  sb_putc(md, '\n');
  sb_putn(md, h2.s, h2.len);
  sb_putc(md, '\n');
  sb_free(&h2);

  while(!undefinable){
    sword rc = OCIStmtFetch2(stmt, err, 1, OCI_FETCH_NEXT, 0, OCI_DEFAULT);
    if(rc == OCI_NO_DATA) break;
    if(rc != OCI_SUCCESS && rc != OCI_SUCCESS_WITH_INFO) break;
    sb_puts(md, "|");
    for(ub4 i = 0; i < nf; i++){
      sb_putc(md, ' ');
      if(c[i].ind == -1) sb_puts(md, "*null*");
      else if(c[i].is_lob){
        size_t n = 0;
        char *v = lob_read(c[i].lob, c[i].dtype == SQLT_BLOB, c[i].csform, &n);
        if(v){ md_cell(md, v, n); free(v); }
      }
      else if(c[i].is_raw) hex_upper(md, (unsigned char *)c[i].buf, c[i].rlen);
      else md_cell(md, c[i].buf, strlen(c[i].buf));
      sb_puts(md, " |");
    }
    sb_putc(md, '\n');
  }

  for(ub4 i = 0; i < nf; i++){
    free(c[i].name);
    free(c[i].buf);
    if(c[i].lob) OCIDescriptorFree(c[i].lob, OCI_DTYPE_LOB);
  }
  free(c);
}

static void exec_simple(const char *sql){
  OCIStmt *s = NULL;
  if(OCIStmtPrepare2(svc, &s, err, (const OraText *)sql, (ub4)strlen(sql),
                     NULL, 0, OCI_NTV_SYNTAX, OCI_DEFAULT) != OCI_SUCCESS) return;
  OCIStmtExecute(svc, s, err, 1, 0, NULL, NULL, OCI_DEFAULT);
  OCIStmtRelease(s, err, NULL, 0, OCI_DEFAULT);
}

/* dbms_random's implicit seed is one-second granular on this version, so fiddles that
   start in the same second on a byte-identical restore share one */
static void seed_random(void){
  unsigned char b[16];
  if(getrandom(b, sizeof b, 0) != (int)sizeof b) return;
  char sql[64] = "call dbms_random.seed('";
  size_t k = strlen(sql);
  for(size_t i = 0; i < sizeof b; i++) k += (size_t)sprintf(sql + k, "%02X", b[i]);
  strcpy(sql + k, "')");
  exec_simple(sql);
}

static char *fetch_dbms_output(void){
  static const char *sql = "select fiddle.dbmsoutput() from dual";
  OCIStmt *s = NULL;
  char *buf = NULL;
  if(OCIStmtPrepare2(svc, &s, err, (const OraText *)sql, (ub4)strlen(sql),
                     NULL, 0, OCI_NTV_SYNTAX, OCI_DEFAULT) != OCI_SUCCESS) return NULL;
  if(OCIStmtExecute(svc, s, err, 0, 0, NULL, NULL, OCI_DEFAULT) == OCI_SUCCESS){
    buf = malloc(32768);
    if(!buf) oom();
    buf[0] = 0;
    sb2 ind = 0;
    OCIDefine *dfn = NULL;
    OCIDefineByPos(s, &dfn, err, 1, buf, 32768, SQLT_STR, &ind, NULL, NULL, OCI_DEFAULT);
    sword rc = OCIStmtFetch2(s, err, 1, OCI_FETCH_NEXT, 0, OCI_DEFAULT);
    if(rc != OCI_SUCCESS || ind == -1){ free(buf); buf = NULL; }
  }
  OCIStmtRelease(s, err, NULL, 0, OCI_DEFAULT);
  return buf;
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

static int connect_db(void){
#ifdef AL32UTF8_ID
  ub2 cs = AL32UTF8_ID;
#else
  OCIEnv *probe = NULL;
  if(OCIEnvCreate(&probe, OCI_DEFAULT, NULL, NULL, NULL, NULL, 0, NULL) != OCI_SUCCESS)
    return 0;
  ub2 cs = OCINlsCharSetNameToId(probe, (const oratext *)"AL32UTF8");
  OCIHandleFree(probe, OCI_HTYPE_ENV);
#endif
  if(OCIEnvNlsCreate(&env, OCI_OBJECT, NULL, NULL, NULL, NULL, 0, NULL, cs, cs)
     != OCI_SUCCESS) return 0;
  OCIHandleAlloc(env, (void **)&err, OCI_HTYPE_ERROR, 0, NULL);
  return OCILogon2(env, err, &svc,
                   (const OraText *)"fiddle", 6,
                   (const OraText *)"IIGjTTbsEzh64McU", 16,
                   (const OraText *)"localhost/xepdb1", 16,
                   OCI_DEFAULT) == OCI_SUCCESS;
}

static void trim_batch(char *s, size_t *len){
  size_t n = *len;
  while(n && strchr(" \t\n\r\013", s[n - 1]) && s[n - 1]) n--;
  if(n && s[n - 1] == '/'){ while(n && s[n - 1] == '/') n--; }
  else { while(n && s[n - 1] == ';') n--; }
  s[n] = 0;
  *len = n;
}

int main(int argc, char **argv){
  int warmup = argc > 1 && strcmp(argv[1], "--warmup") == 0;
  const char *inpath  = (!warmup && argc > 1) ? argv[1] : "/tmp/batches.json";
  const char *outpath = (!warmup && argc > 2) ? argv[2] : "/tmp/output.json";

  if(!connect_db()){
    sbuf e = {0};
    oci_msg(&e, err, OCI_HTYPE_ERROR);
    fprintf(stderr, "Could not connect to the server: %s\n", e.s ? e.s : "");
    fputs("Could not connect to the server", stdout);
    return 1;
  }
  /* prints the table: `warm-up:` in the ceremony log is the only evidence it connected */
  if(warmup){
    sbuf md = {0};
    OCIStmt *stmt = NULL;
    static const char *sql = "select 1 from dual";
    if(OCIStmtPrepare2(svc, &stmt, err, (const OraText *)sql, (ub4)strlen(sql),
                       NULL, 0, OCI_NTV_SYNTAX, OCI_DEFAULT) == OCI_SUCCESS){
      if(OCIStmtExecute(svc, stmt, err, 0, 0, NULL, NULL, OCI_DEFAULT) == OCI_SUCCESS){
        ub4 nf = 0;
        OCIAttrGet(stmt, OCI_HTYPE_STMT, &nf, NULL, OCI_ATTR_PARAM_COUNT, err);
        if(nf) render_result(&md, stmt, nf);
      }
      OCIStmtRelease(stmt, err, NULL, 0, OCI_DEFAULT);
    }
    printf("warm-up: %s", md.len ? md.s : "FAILED\n");
    sb_free(&md);
    OCILogoff(svc, err);
    return 0;
  }
  seed_random();

  size_t blen = 0, nb = 0;
  char *btext = read_file(inpath, &blen);
  batch *batches = btext ? parse_batches(btext, &nb) : NULL;

  sbuf out = {0};
  sb_putc(&out, '[');
  for(size_t i = 0; i < nb; i++){
    sbuf md = {0};
    int dbmsoutput = strcasestr(batches[i].s, "dbms_output") != NULL;
    trim_batch(batches[i].s, &batches[i].len);
    if(dbmsoutput) exec_simple("call dbms_output.enable()");

    OCIStmt *stmt = NULL;
    if(batches[i].len == 0){ /* an empty batch yields neither rows nor error */ }
    else if(OCIStmtPrepare2(svc, &stmt, err, (const OraText *)batches[i].s,
                       (ub4)batches[i].len, NULL, 0, OCI_NTV_SYNTAX,
                       OCI_DEFAULT) == OCI_SUCCESS){
      ub2 stype = 0;
      OCIAttrGet(stmt, OCI_HTYPE_STMT, &stype, NULL, OCI_ATTR_STMT_TYPE, err);
      ub4 iters = stype == OCI_STMT_SELECT ? 0 : 1;
      sword rc = OCIStmtExecute(svc, stmt, err, iters, 0, NULL, NULL, OCI_DEFAULT);
      if(rc == OCI_SUCCESS || rc == OCI_SUCCESS_WITH_INFO){
        ub4 nf = 0;
        OCIAttrGet(stmt, OCI_HTYPE_STMT, &nf, NULL, OCI_ATTR_PARAM_COUNT, err);
        if(nf){
          render_result(&md, stmt, nf);
          sb_putc(&md, '\n');
        } else {
          ub4 rows = 0;
          OCIAttrGet(stmt, OCI_HTYPE_STMT, &rows, NULL, OCI_ATTR_ROW_COUNT, err);
          if(rows){
            char t[64];
            int n = snprintf(t, sizeof t, "%u rows affected", rows);
            fence_block(&md, t, (size_t)n, "status");
          }
        }
      } else {
        sbuf e = {0};
        oci_msg(&e, err, OCI_HTYPE_ERROR);
        fence_block(&md, e.s ? e.s : "", e.len, "error");
        sb_free(&e);
      }
      OCIStmtRelease(stmt, err, NULL, 0, OCI_DEFAULT);
    } else {
      sbuf e = {0};
      oci_msg(&e, err, OCI_HTYPE_ERROR);
      fence_block(&md, e.s ? e.s : "", e.len, "error");
      sb_free(&e);
    }

    if(dbmsoutput){
      char *o = fetch_dbms_output();
      if(o){ fence_block(&md, o, strlen(o), "dbms_output"); free(o); }
      exec_simple("call dbms_output.disable()");
    }

    if(i) sb_putc(&out, ',');
    json_emit_string(&out, md.s ? md.s : "", md.len);
    sb_free(&md);
  }
  sb_putc(&out, ']');
  OCILogoff(svc, err);

  FILE *f = fopen(outpath, "wb");
  if(!f) return 1;
  fwrite(out.s, 1, out.len, f);
  fclose(f);
  return 0;
}
EOC
OH=/opt/oracle/product/21c/dbhomeXE
chroot /mnt/fire/oracle_21/mnt /usr/bin/gcc -O2 -o /probe /probe.c -I$OH/rdbms/public -L$OH/lib -lclntsh
CSID=$(chroot /mnt/fire/oracle_21/mnt /usr/bin/env ORACLE_HOME=$OH /probe)
chroot /mnt/fire/oracle_21/mnt /usr/bin/gcc -O2 -Wall -DAL32UTF8_ID=$CSID -o /fiddle /fiddle.c \
  -I$OH/rdbms/public -L$OH/lib -lclntsh
rm -f /mnt/fire/oracle_21/mnt/fiddle.c /mnt/fire/oracle_21/mnt/probe.c /mnt/fire/oracle_21/mnt/probe
chroot /mnt/fire/oracle_21/mnt /usr/bin/ldd /fiddle

install -m 755 /mnt/fire/oracle_21/vsock /mnt/fire/oracle_21/mnt/vsock

umount /mnt/fire/oracle_21/mnt

# read the headroom after the umount: before it the superblock still shows the empty image
free_mb=$(dumpe2fs -h /mnt/fire/oracle_21/rootfs.ext4 2>/dev/null \
  | awk '/^Free blocks:/{f=$3} /^Block size:/{b=$3} END{print int(f*b/1048576)}')
echo "rootfs free: ${free_mb}M"
[ "${free_mb:-0}" -ge 50 ] || { echo "FAIL: under 50M free - raise the dd count= above and rebuild"; exit 1; }

zfs set recordsize=16K tank/fire/oracle_21

( cd /mnt/fire/oracle_21
  rm -f mem vmstate v.sock* /tmp/fc-snap-oracle_21.sock /tmp/fc-snap-oracle_21.log
  firecracker-1.13 --api-sock /tmp/fc-snap-oracle_21.sock --config-file config.json > /tmp/fc-snap-oracle_21.log 2>&1 &
  until grep -q FIDDLE-READY /tmp/fc-snap-oracle_21.log ; do sleep 0.1 ; done
  curl -sf --unix-socket /tmp/fc-snap-oracle_21.sock -X PATCH http://localhost/vm -H 'Content-Type: application/json' -d '{"state":"Paused"}'
  curl -sf --unix-socket /tmp/fc-snap-oracle_21.sock -X PUT http://localhost/snapshot/create -H 'Content-Type: application/json' -d '{"snapshot_type":"Full","snapshot_path":"vmstate","mem_file_path":"mem"}'
  kill $! || true )
# a cold snapshot just serves slowly: check the warm-up ran
grep -a 'warm-up:' /tmp/fc-snap-oracle_21.log

# never -R: on a live engine it destroys the clones of in-flight fiddles
zfs destroy tank/fire/oracle_21@base 2>/dev/null || true
zfs snapshot tank/fire/oracle_21@base

cd /
out=$(echo '["select 1 from dual"]' | /mnt/fire/oracle_21/run.sh) || true
printf '%s\n' "$out"
# run.sh has no meaningful exit status: assert on the body
[ -n "$out" ] || { echo "ABORT: verification fiddle returned an empty body"; exit 1; }
