# mssql-server comes from the mssql-server-2019 channel, which cannot cross into a later
# release. Never take it from prod.list's unversioned package.
echo 'www-data        ALL=(ALL) NOPASSWD: /mnt/fire/sqlserver_2019l/run.sh' >> /etc/sudoers
zfs create tank/fire/sqlserver_2019l
cp /mnt/fire/vmlinux-6.1.141 /mnt/fire/sqlserver_2019l/vmlinux.bin

# masking invariant TSC (CPUID 0x80000007 EDX bit 8) makes SQLPAL time its scheduler off
# the OS clock, which survives restore; raw rdtsc jumps by the snapshot's age and asserts
<<'EOF' cat > /mnt/fire/sqlserver_2019l/cpu_template.json
{
  "cpuid_modifiers": [
    {
      "leaf": "0x80000007",
      "subleaf": "0x0",
      "flags": 0,
      "modifiers": [
        { "register": "edx", "bitmap": "0bxxxxxxxxxxxxxxxxxxxxxxx0xxxxxxxx" }
      ]
    }
  ]
}
EOF

# no-kvmapf: without it a restored sqlservr loses #SchedMonitor and #WorkerFactory to async
# page faults that never complete, and stops accepting logins
<<'EOF' cat > /mnt/fire/sqlserver_2019l/config.json
{
  "boot-source": {
    "kernel_image_path": "vmlinux.bin",
    "boot_args": "console=ttyS0 no-kvmapf reboot=k panic=1 pci=off random.trust_cpu=on"
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
  "cpu-config": "cpu_template.json",
  "machine-config": {
    "vcpu_count": 2,
    "mem_size_mib": 4096
  }
}
EOF

<<'EOF' cat > /mnt/fire/sqlserver_2019l/vsock.c
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
gcc -O2 -static -o /mnt/fire/sqlserver_2019l/vsock /mnt/fire/sqlserver_2019l/vsock.c

# reseedrng: the per-restore run must read the bases --scan recorded at the ceremony, since
# a full scan costs ~5s per fiddle. It zeroes each state's cache as well as re-keying it,
# or cached output is still served.
<<'EOF' cat > /mnt/fire/sqlserver_2019l/reseedrng.c
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <stdint.h>
#include <inttypes.h>

#define TABLE_RVA 0x75840          /* bcryptPrimitives.dll .data: per-processor DRBG table */
#define ST_KEY    0x10             /* 64 bytes: AES key + V */
#define ST_AVAIL  0x70             /* 8 bytes: bytes left in cache */
#define ST_CACHE  0xb0             /* 96 bytes: output cache */

static long find_sqlservr(void){
  DIR *d = opendir("/proc");
  struct dirent *e; long pid = -1, best = -1;
  if(!d) return -1;
  while((e = readdir(d))){
    long p = atol(e->d_name);
    if(p <= 0) continue;
    char path[64], buf[256];
    snprintf(path, sizeof path, "/proc/%ld/comm", p);
    int fd = open(path, O_RDONLY); if(fd < 0) continue;
    int n = read(fd, buf, sizeof buf - 1); close(fd);
    if(n <= 0) continue; buf[n] = 0;
    if(strncmp(buf, "sqlservr", 8)) continue;
    snprintf(path, sizeof path, "/proc/%ld/statm", p);
    fd = open(path, O_RDONLY); if(fd < 0) continue;
    n = read(fd, buf, sizeof buf - 1); close(fd);
    long rss = 0; if(n > 0){ buf[n] = 0; char *sp = strchr(buf, ' '); if(sp) rss = atol(sp + 1); }
    if(rss > best){ best = rss; pid = p; }
  }
  closedir(d);
  return pid;
}

static int rekey_at(int mem, int u, uint64_t base){
  int done = 0;
  for(int g = 0; g < 32; g++){
    uint64_t grp = 0;
    if(pread(mem, &grp, 8, base + TABLE_RVA + 8*g) != 8 || !grp) continue;
    for(int c = 0; c < 64; c++){
      uint64_t st = 0;
      if(pread(mem, &st, 8, grp + 8*c) != 8 || !st) continue;
      unsigned char key[64], zero[96] = {0};
      uint64_t avail = 0;
      if(read(u, key, sizeof key) != (ssize_t)sizeof key) return -1;
      if(pwrite(mem, key, sizeof key, st + ST_KEY) != (ssize_t)sizeof key) continue;
      if(pwrite(mem, &avail, 8, st + ST_AVAIL) != 8) continue;
      if(pwrite(mem, zero, sizeof zero, st + ST_CACHE) != (ssize_t)sizeof zero) continue;
      done++;
    }
  }
  return done;
}

int main(int argc, char **argv){
  int scan = argc > 1 && !strcmp(argv[1], "--scan");
  const char *basefile = scan ? (argc > 2 ? argv[2] : 0) : (argc > 1 ? argv[1] : 0);
  if(!basefile){ fprintf(stderr, "usage: reseedrng [--scan] <basefile>\n"); return 2; }

  long pid = find_sqlservr();
  if(pid <= 0){ fprintf(stderr, "RESEEDRNG: no sqlservr process\n"); return 1; }

  char p[64];
  snprintf(p, sizeof p, "/proc/%ld/mem", pid);
  int mem = open(p, O_RDWR);
  if(mem < 0){ perror("RESEEDRNG: mem"); return 1; }
  int u = open("/dev/urandom", O_RDONLY);
  if(u < 0){ perror("RESEEDRNG: urandom"); return 1; }

  int done = 0, mods = 0;

  if(!scan){
    FILE *bf = fopen(basefile, "r");
    if(!bf){ fprintf(stderr, "RESEEDRNG: no base file %s\n", basefile); return 1; }
    char l[64];
    while(fgets(l, sizeof l, bf)){
      uint64_t b = strtoull(l, 0, 16);
      if(!b) continue;
      /* cheap sanity check that the recorded base is still a PE, so a stale file is
         caught rather than scribbling on whatever now lives there */
      unsigned char h[2];
      if(pread(mem, h, 2, b) != 2 || h[0] != 'M' || h[1] != 'Z') continue;
      mods++;
      int n = rekey_at(mem, u, b);
      if(n < 0){ perror("RESEEDRNG: urandom"); return 1; }
      done += n;
    }
    fclose(bf);
    close(mem); close(u);
    fprintf(stderr, "RESEEDRNG: %d bcryptPrimitives copies, %d states re-keyed\n", mods, done);
    return done ? 0 : 2;
  }

  snprintf(p, sizeof p, "/proc/%ld/maps", pid);
  FILE *maps = fopen(p, "r");
  if(!maps){ perror("RESEEDRNG: maps"); return 1; }
  FILE *out = fopen(basefile, "w");
  if(!out){ perror("RESEEDRNG: basefile"); return 1; }

  char line[1024];
  while(fgets(line, sizeof line, maps)){
    uint64_t lo, hi; char perms[8];
    if(sscanf(line, "%" SCNx64 "-%" SCNx64 " %7s", &lo, &hi, perms) < 3) continue;
    if(perms[0] != 'r') continue;
    for(uint64_t a = lo; a + 0x1000 <= hi; a += 0x1000){
      unsigned char h[2];
      if(pread(mem, h, 2, a) != 2) break;
      if(h[0] != 'M' || h[1] != 'Z') continue;
      uint32_t lf = 0;
      if(pread(mem, &lf, 4, a + 0x3c) != 4 || !lf || lf > 0x1000) continue;
      char sig[4];
      if(pread(mem, sig, 4, a + lf) != 4 || memcmp(sig, "PE\0\0", 4)) continue;
      uint32_t exp_rva = 0, nrva = 0; char nm[64] = {0};
      if(pread(mem, &exp_rva, 4, a + lf + 24 + 112) != 4 || !exp_rva) continue;
      if(pread(mem, &nrva, 4, a + exp_rva + 12) != 4 || !nrva) continue;
      if(pread(mem, nm, sizeof nm - 1, a + nrva) <= 0) continue;
      if(strcasecmp(nm, "bcryptPrimitives.dll")) continue;
      mods++;
      fprintf(out, "%" PRIx64 "\n", a);
      int n = rekey_at(mem, u, a);
      if(n < 0){ perror("RESEEDRNG: urandom"); return 1; }
      done += n;
    }
  }
  fclose(maps); fclose(out); close(mem); close(u);
  fprintf(stderr, "RESEEDRNG: %d bcryptPrimitives copies, %d states re-keyed\n", mods, done);
  /* non-zero when nothing was re-keyed: the ceremony greps for the count */
  return done ? 0 : 2;
}
EOF
gcc -O2 -static -o /mnt/fire/sqlserver_2019l/reseedrng /mnt/fire/sqlserver_2019l/reseedrng.c

# never write listener.pl here: /mnt/fire/listener.pl is shared by every engine

<<'EOF' cat > /mnt/fire/sqlserver_2019l/run.sh
#!/bin/bash
# never pass "$@" through: the sudoers line has no argument spec, so any argument is
# permitted and the caller would be choosing the engine
exec /mnt/fire/run.sh "$(basename "$(dirname "$(readlink -f "$0")")")"
EOF

chmod 700 /mnt/fire/sqlserver_2019l/run.sh

mkdir /mnt/fire/sqlserver_2019l/mnt
mkdir /mnt/fire/sqlserver_2019l/build

# fiddle.cs is shared across the sqlserver family apart from the sample database and 2025's
# languages: carry a change to every copy.
<<'EOF' cat > /mnt/fire/sqlserver_2019l/build/fiddle.csproj
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>disable</Nullable>
    <AssemblyName>fiddle</AssemblyName>
    <InvariantGlobalization>false</InvariantGlobalization>
  </PropertyGroup>
  <ItemGroup>
    <!-- 4.1.1: dotMorten binds IBinarySerialize, which left Microsoft.Data.SqlClient in 5.0.
         nuget silently resolves a nonexistent version to a newer one (NU1603), so check
         the publish log on a bump. -->
    <PackageReference Include="Microsoft.Data.SqlClient" Version="[4.1.1]" />
    <PackageReference Include="dotMorten.Microsoft.SqlServer.Types" Version="2.5.0" />
  </ItemGroup>
</Project>
EOF

<<'EOF' cat > /mnt/fire/sqlserver_2019l/build/fiddle.cs
using System;
using System.Collections.Generic;
using System.Data;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml;
using Microsoft.Data.SqlClient;
using Microsoft.SqlServer.Types;

class Fiddle
{
    const string SaConnection = "Initial Catalog=master;Server=localhost;Encrypt=False;User Id=sa;Password=Fiddle2b3E4f5A6b7c8D";
    // Type System Version=SQL Server 2008 decides how several types reach the reader: it
    // changes results, not just the connection.
    const string FiddleConnection = "Initial Catalog=fiddle;Server=localhost;Encrypt=False;Type System Version=SQL Server 2008;Pooling=False;User Id=sa;Password=Fiddle2b3E4f5A6b7c8D";

    static readonly string[] NumericTypes = { "int", "bigint", "smallint", "tinyint", "float", "real", "decimal", "numeric", "money", "smallmoney" };
    static readonly string[] BinaryTypes = { "varbinary", "binary", "image", "timestamp" };

    static string EscapeMarkdownCell(string m)
    {
        m = Regex.Replace(m, @"[[*/|`_<&\\]", @"\$0");
        m = Regex.Replace(m, "^[ \t]+", mm => mm.Value.Replace(" ", "&numsp;").Replace("\t", "&#9;"), RegexOptions.Multiline);
        m = m.Replace("\t", "&#9;");
        m = Regex.Replace(m, "\r\n|\r|\n", "<br>");
        return m;
    }

    static string Backtick(string m, string s)
    {
        int longest = 0, current = 0;
        foreach (char c in m) { if (c == '`') { current++; if (current > longest) longest = current; } else current = 0; }
        string fence = new string('`', Math.Max(3, longest + 1));
        return Regex.Replace(fence + " " + s + "\n" + m + "\n" + fence, "^", "> ", RegexOptions.Multiline) + "\n\n";
    }

    static string PrettyXml(string xml)
    {
        var sw = new StringWriter();
        var xw = new XmlTextWriter(sw) { Formatting = Formatting.Indented, Indentation = 2 };
        var doc = new XmlDocument();
        doc.LoadXml(xml);
        doc.Save(xw);
        return sw.ToString();
    }

    // a restored guest sometimes needs longer than SqlClient's 15s connect timeout
    static void OpenWithRetry(SqlConnection c)
    {
        var deadline = DateTime.UtcNow.AddSeconds(90);
        for (;;)
        {
            try { c.Open(); return; }
            catch (Exception) when (DateTime.UtcNow < deadline)
            { System.Threading.Thread.Sleep(200); }
        }
    }

    static void Main(string[] args)
    {
        CultureInfo.DefaultThreadCurrentCulture = new CultureInfo("en-US");

        if (args.Length > 0 && args[0] == "ping")
        {
            try { using var ping = new SqlConnection(SaConnection); ping.Open(); Environment.Exit(0); }
            catch { Environment.Exit(1); }
        }

        var queries = JsonSerializer.Deserialize<List<string>>(File.ReadAllText("/tmp/batches.json"));

        var ret = new List<string>();

        var connection = new SqlConnection(FiddleConnection);
        OpenWithRetry(connection);
        var command = connection.CreateCommand();
        command.CommandText = "SET ANSI_NULLS, ANSI_PADDING, ANSI_WARNINGS, ARITHABORT, CONCAT_NULL_YIELDS_NULL, QUOTED_IDENTIFIER ON";
        command.ExecuteNonQuery();
        command = connection.CreateCommand();
        command.CommandText = "SET NUMERIC_ROUNDABORT OFF";
        command.ExecuteNonQuery();

        // reseeds rand() from newid(); a restored guest's session seed is otherwise near-constant
        command = connection.CreateCommand();
        command.CommandText = "select rand(checksum(newid()))";
        command.ExecuteNonQuery();

        foreach (string query in queries)
        {
            var markdown = new StringBuilder();
            SqlDataReader reader = null;
            try
            {
                command = connection.CreateCommand();
                command.CommandText = query;
                command.CommandTimeout = 25;
                try
                {
                    do
                    {
                        var message = new StringBuilder();
                        SqlInfoMessageEventHandler handler = (sender, a) => { foreach (SqlError e in a.Errors) message.Append(e.Message + "\n"); };
                        connection.InfoMessage += handler;

                        if (reader == null)
                            reader = command.ExecuteReader();
                        else if (!reader.NextResult())
                            break; // quirk kept: handler stays attached, trailing messages are dropped

                        if (reader.FieldCount > 0)
                        {
                            var schema = reader.GetSchemaTable();
                            var precisionFormat = new string[reader.FieldCount];
                            var head = new string[reader.FieldCount];
                            var alignRight = new bool[reader.FieldCount];
                            var head1 = new StringBuilder("|");
                            var head2 = new StringBuilder("|");
                            for (int i = 0; i < reader.FieldCount; i++)
                            {
                                if (reader.GetName(i) == "")
                                    head[i] = "(No column name)"; // quirk kept: precisionFormat stays empty
                                else
                                {
                                    head[i] = reader.GetName(i);
                                    short scale = Convert.ToInt16(schema.Rows[i]["NumericScale"]);
                                    precisionFormat[i] = scale > 0 ? "'.'" + new string('f', scale) : "";
                                }
                                alignRight[i] = NumericTypes.Contains(reader.GetDataTypeName(i));
                                head1.Append(' ').Append(EscapeMarkdownCell(head[i])).Append(" |");
                                head2.Append(alignRight[i] ? '-' : ':').Append(new string('-', head[i].Length)).Append(alignRight[i] ? ':' : '-').Append('|');
                            }
                            markdown.Append(head1).Append('\n').Append(head2).Append('\n');
                            while (reader.Read())
                            {
                                markdown.Append('|');
                                for (int i = 0; i < reader.FieldCount; i++)
                                {
                                    markdown.Append(' ');
                                    markdown.Append(reader.IsDBNull(i) ? "*null*" : EscapeMarkdownCell(FormatCell(reader, i, precisionFormat[i])));
                                    markdown.Append(" |");
                                }
                                markdown.Append('\n');
                            }
                            markdown.Append('\n');
                        }
                        else
                        {
                            if (reader.RecordsAffected > 0) message.Append(reader.RecordsAffected + " rows affected");
                        }
                        if (message.Length > 0) markdown.Append(Backtick(message.ToString().TrimEnd('\n'), "status"));
                        connection.InfoMessage -= handler;
                    } while (true);
                }
                finally
                {
                    try { reader.Close(); } catch { }
                    reader = null;
                }
            }
            catch (SqlException ex)
            {
                var error = new StringBuilder();
                for (int i = 0; i < ex.Errors.Count; i++)
                {
                    if (i > 0) error.Append('\n');
                    error.Append("Msg " + ex.Errors[i].Number + " Level " + ex.Errors[i].Class + " State " + ex.Errors[i].State + " Line " + ex.Errors[i].LineNumber + "\n" + ex.Errors[i].Message);
                }
                markdown.Append(Backtick(error.ToString(), "error"));
            }
            catch (Exception ex)
            {
                markdown.Append(Backtick(ex.Message + "\n" + ex.StackTrace, "error"));
            }
            ret.Add(markdown.ToString());
        }

        connection.Close();
        File.WriteAllText("/tmp/output.json", JsonSerializer.Serialize(ret));
    }

    static string FormatCell(SqlDataReader reader, int i, string precisionFormat)
    {
        string type = reader.GetDataTypeName(i);
        if (BinaryTypes.Contains(type))
            return "0x" + Convert.ToHexString((byte[])reader[i]);
        if (type == "decimal")
            return reader.GetSqlDecimal(i).ToString();
        if (type == "date")
            return reader.GetDateTime(i).ToString("yyyy-MM-dd");
        if (type == "smalldatetime")
            return reader.GetDateTime(i).ToString("yyyy-MM-dd HH:mm");
        if (type == "datetime")
            return reader.GetDateTime(i).ToString("yyyy-MM-dd HH:mm:ss.fff");
        if (type == "datetime2")
            return reader.GetDateTime(i).ToString("yyyy-MM-dd HH:mm:ss" + precisionFormat);
        if (type == "time")
            return reader.GetTimeSpan(i).ToString("hh':'mm':'ss" + precisionFormat);
        if (type == "datetimeoffset")
            return reader.GetDateTimeOffset(i).ToString("yyyy-MM-dd HH:mm:ss" + precisionFormat + " zzz");
        if (type == "xml")
            return PrettyXml(reader[i].ToString());
        // G15/G7 explicitly: .NET Core's default is shortest-roundtrip, which changes output
        if (type == "float")
            return reader.GetDouble(i).ToString("G15");
        if (type == "real")
            return reader.GetFloat(i).ToString("G7");
        // CLR UDTs via the cross-platform port: Microsoft.SqlServer.Types is windows-only
        if (type == "geometry" || type.EndsWith(".geometry"))
            return SqlGeometry.Deserialize(reader.GetSqlBytes(i)).ToString();
        if (type == "geography" || type.EndsWith(".geography"))
            return SqlGeography.Deserialize(reader.GetSqlBytes(i)).ToString();
        if (type == "hierarchyid" || type.EndsWith(".hierarchyid"))
        {
            var h = new SqlHierarchyId();
            using var br = new BinaryReader(reader.GetSqlBytes(i).Stream);
            h.Read(br);
            return h.ToString();
        }
        return reader[i].ToString();
    }
}
EOF

<<'EOF' cat > /mnt/fire/sqlserver_2019l/build/Dockerfile
FROM ubuntu:20.04 AS build
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl gnupg ca-certificates \
 && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
 && curl -fsSL https://packages.microsoft.com/config/ubuntu/20.04/prod.list -o /etc/apt/sources.list.d/mssql-prod.list \
 && sed -i 's|\[arch=\([^]]*\)\]|[arch=\1 signed-by=/usr/share/keyrings/microsoft-prod.gpg]|' /etc/apt/sources.list.d/*.list
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y dotnet-sdk-8.0
COPY fiddle.csproj fiddle.cs /src/
RUN cd /src && dotnet publish -c Release -o /app

FROM ubuntu:20.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
      systemd systemd-sysv ca-certificates curl gnupg locales tmux vim-tiny \
 && locale-gen en_US.UTF-8
RUN curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
 && curl -fsSL https://packages.microsoft.com/config/ubuntu/20.04/mssql-server-2019.list -o /etc/apt/sources.list.d/mssql-server-2019.list \
 && curl -fsSL https://packages.microsoft.com/config/ubuntu/20.04/prod.list -o /etc/apt/sources.list.d/mssql-prod.list \
 && sed -i 's|\[arch=\([^]]*\)\]|[arch=\1 signed-by=/usr/share/keyrings/microsoft-prod.gpg]|' /etc/apt/sources.list.d/*.list
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y mssql-server dotnet-runtime-8.0 \
 && ACCEPT_EULA=Y DEBIAN_FRONTEND=noninteractive apt-get install -y mssql-tools18 unixodbc \
 && dpkg-query -W -f='MSSQL-BUILD=${Version}\n' mssql-server
# ^ records the resolved CU in the build log
COPY --from=build /app /opt/fiddle-app
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
RUN apt-get clean
RUN echo "root:Docker!" | chpasswd
ENTRYPOINT ["bash"]
EOF

# per-engine tag: concurrent builds on cumbria2 must never share one
docker build -t dummy_sqlserver_2019l /mnt/fire/sqlserver_2019l/build
# 1760M = 1619M content + 65M ext4 metadata + 76M free. Re-derive it; never copy a sibling's.
dd if=/dev/zero bs=1M count=1760 > /mnt/fire/sqlserver_2019l/rootfs.ext4
mkfs.ext4 -m 0 /mnt/fire/sqlserver_2019l/rootfs.ext4
mount -o loop /mnt/fire/sqlserver_2019l/rootfs.ext4 /mnt/fire/sqlserver_2019l/mnt
docker run --rm -i -v /mnt/fire/sqlserver_2019l/mnt:/my-rootfs dummy_sqlserver_2019l -s <<"SETUP"
for d in bin etc home lib lib64 opt root sbin usr dev run var; do tar c "/$d" | tar x -C /my-rootfs; done
for dir in proc sys; do mkdir /my-rootfs/${dir}; done
mknod -m 666 /my-rootfs/dev/ttyS0 c 4 64
SETUP
# drop the image: cumbria2's root filesystem fills otherwise
docker rmi dummy_sqlserver_2019l

cp /mnt/fire/sqlserver_2019l/vsock /mnt/fire/sqlserver_2019l/mnt/vsock
chmod 755 /mnt/fire/sqlserver_2019l/mnt/vsock
cp /mnt/fire/sqlserver_2019l/reseedrng /mnt/fire/sqlserver_2019l/mnt/reseedrng
chmod 755 /mnt/fire/sqlserver_2019l/mnt/reseedrng

# replace docker's bind-mounted network identity with the guest's offline one
printf '127.0.0.1 localhost fiddle\n::1 localhost\n' > /mnt/fire/sqlserver_2019l/mnt/etc/hosts
echo fiddle > /mnt/fire/sqlserver_2019l/mnt/etc/hostname
: > /mnt/fire/sqlserver_2019l/mnt/etc/resolv.conf
rm -f /mnt/fire/sqlserver_2019l/mnt/etc/systemd/system/multi-user.target.wants/mssql-server.service

# ---- init boot ----
<<'EOF' cat > /mnt/fire/sqlserver_2019l/mnt/fiddle.sh
#!/bin/sh
export ACCEPT_EULA=Y MSSQL_SA_PASSWORD=Fiddle2b3E4f5A6b7c8D MSSQL_PID=Express LANG=en_US.UTF-8
/opt/mssql/bin/mssql-conf -n setup accept-eula > /dev/console 2>&1
/opt/mssql/bin/mssql-conf traceflag 460 on > /dev/console 2>&1
/opt/mssql/bin/mssql-conf set telemetry.customerfeedback false > /dev/console 2>&1
# no master key: a fiddle that creates one must keep succeeding
runuser -u mssql -- /opt/mssql/bin/sqlservr > /dev/console 2>&1 &
until /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P Fiddle2b3E4f5A6b7c8D -C -l 5 -Q 'select 1' > /dev/null 2>&1; do sleep 1; done
/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P Fiddle2b3E4f5A6b7c8D -C -b -Q "create database fiddle" > /dev/console 2>&1
echo "FIDDLE-DB-RC=$?" > /dev/console
/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P Fiddle2b3E4f5A6b7c8D -C -b -d fiddle \
  -Q "alter database current set allow_snapshot_isolation on;" > /dev/console 2>&1
echo "FIDDLE-DB-STATE-RC=$?" > /dev/console
sync
echo FIDDLE-INIT-DONE > /dev/console
reboot -ff
EOF
chmod 700 /mnt/fire/sqlserver_2019l/mnt/fiddle.sh
umount /mnt/fire/sqlserver_2019l/mnt

cd /mnt/fire/sqlserver_2019l
rm -f /tmp/fc-init-sqlserver_2019l.log
firecracker-1.13 --no-api --config-file config.json > /tmp/fc-init-sqlserver_2019l.log 2>&1
grep FIDDLE-INIT-DONE /tmp/fc-init-sqlserver_2019l.log   # must appear; if not, read the log
grep -a 'FIDDLE-DB-RC=0' /tmp/fc-init-sqlserver_2019l.log        # the `fiddle` database was created
grep -a 'FIDDLE-DB-STATE-RC=0' /tmp/fc-init-sqlserver_2019l.log  # ...with snapshot isolation on

# ---- real fiddle.sh, then snapshot ceremony ----
# any edit to fiddle.sh or /opt/fiddle-app invalidates the snapshot: re-run the ceremony
mount -o loop /mnt/fire/sqlserver_2019l/rootfs.ext4 /mnt/fire/sqlserver_2019l/mnt
# setup re-enables mssql-server.service; fiddle.sh owns the sqlservr start
rm -f /mnt/fire/sqlserver_2019l/mnt/etc/systemd/system/multi-user.target.wants/mssql-server.service
<<'EOF' cat > /mnt/fire/sqlserver_2019l/mnt/fiddle.sh
#!/bin/sh
dd if=/dev/random count=1 bs=1
export LANG=en_US.UTF-8
# age the clock 4h so OpenSSL, behind crypt_gen_random, reseeds after every restore. Keep it
# even where a version measures it unneeded.
date -u -s "@$(( $(date -u +%s) - 14400 ))" > /dev/null 2>&1
echo "CLOCK-AGED to $(date -u +%s)" > /dev/console
runuser -u mssql -- /opt/mssql/bin/sqlservr > /dev/console 2>&1 &
until /usr/bin/dotnet /opt/fiddle-app/fiddle.dll ping ; do sleep 0.2 ; done
echo SQLSERVR-WARM > /dev/console
# records the CNG bases, and fails the ceremony if a CU moved the table
/reseedrng --scan /cngbases > /dev/console 2>&1
sync
/vsock serve > /tmp/batches.json
# --- restore resumes here ---
# without this newid() replays one stream on every restore
/reseedrng /cngbases > /dev/console 2>&1
/usr/bin/dotnet /opt/fiddle-app/fiddle.dll > /dev/console 2>&1
/vsock reply < /tmp/output.json
reboot -ff
EOF
chmod 700 /mnt/fire/sqlserver_2019l/mnt/fiddle.sh
umount /mnt/fire/sqlserver_2019l/mnt
# read the headroom after the umount: before it the superblock still shows the empty image
dumpe2fs -h /mnt/fire/sqlserver_2019l/rootfs.ext4 2>/dev/null | grep -E 'Block count|Free blocks|Block size|Reserved block count'
dumpe2fs -h /mnt/fire/sqlserver_2019l/rootfs.ext4 2>/dev/null | awk -F: '
  /^Free blocks/{fb=$2} /^Block size/{bs=$2}
  END{ m = fb*bs/1048576
       if (m < 50 || m > 100) { printf "HEADROOM FAILED: %dM free, want 50-100M - re-derive the dd count above\n", m; exit 1 }
       printf "HEADROOM OK: %dM free\n", m }' || exit 1
# ^ without `|| exit 1` a failed assert carries on into the screen and the snapshot

# ---- ceremony, screened ----
# a ceremony can capture an image prone to the sosschedmon.cpp:219 hang. Screen through
# run.sh after @base exists, and re-roll by redoing the ceremony: re-taking @base over the
# same mem/vmstate changes nothing.
SCREEN_N=150
for attempt in 1 2 3 4; do

cd /mnt/fire/sqlserver_2019l
# per-engine log and socket: a concurrent ceremony on a shared path steals the snapshot
rm -f mem vmstate v.sock* /tmp/fc-snap-sqlserver_2019l.sock /tmp/fc-snap-sqlserver_2019l.log
firecracker-1.13 --api-sock /tmp/fc-snap-sqlserver_2019l.sock --config-file config.json > /tmp/fc-snap-sqlserver_2019l.log 2>&1 &
until grep -q FIDDLE-READY /tmp/fc-snap-sqlserver_2019l.log ; do sleep 0.1 ; done
sleep 0.3
curl -sf --unix-socket /tmp/fc-snap-sqlserver_2019l.sock -X PATCH http://localhost/vm -H 'Content-Type: application/json' -d '{"state":"Paused"}'
curl -sf --unix-socket /tmp/fc-snap-sqlserver_2019l.sock -X PUT http://localhost/snapshot/create -H 'Content-Type: application/json' -d '{"snapshot_type":"Full","snapshot_path":"vmstate","mem_file_path":"mem"}'
kill $! || true
# a snapshot/create that went elsewhere leaves no mem here, and every later step still succeeds
[ -s mem ] && [ -s vmstate ] || { echo 'CEREMONY FAILED: no mem/vmstate in this dataset'; exit 1; }
# a snapshot of a cold guest just serves slowly: assert it is warm and the boot arg took
grep -a SQLSERVR-WARM /tmp/fc-snap-sqlserver_2019l.log       # must appear, BEFORE FIDDLE-READY
grep -a 'Kernel command line' /tmp/fc-snap-sqlserver_2019l.log | grep -a no-kvmapf   # must match
grep -a 'Unknown kernel command line parameters' /tmp/fc-snap-sqlserver_2019l.log    # must NOT match
grep -a CLOCK-AGED /tmp/fc-snap-sqlserver_2019l.log          # randomness lever 1 ran
grep -a 'RESEEDRNG: .* states re-keyed' /tmp/fc-snap-sqlserver_2019l.log   # lever 2's layout still matches
grep -a 'RESEEDRNG: .* 0 states re-keyed' /tmp/fc-snap-sqlserver_2019l.log && echo 'CEREMONY FAILED: CNG layout no longer matches'

# leaked clones block the destroy, leaving a stale @base the snapshot line then trips on
zfs destroy tank/fire/sqlserver_2019l@base 2>/dev/null || true
zfs snapshot tank/fire/sqlserver_2019l@base || echo 'CEREMONY FAILED: stale @base still in place (leaked clones?)'

screen_bad=0
for i in $(seq 1 $SCREEN_N); do
  [ -n "$(echo '["select 1"]' | /mnt/fire/sqlserver_2019l/run.sh 2>/dev/null)" ] || screen_bad=$((screen_bad + 1))
done
echo "SCREEN attempt $attempt: $screen_bad empty of $SCREEN_N"
if [ "$screen_bad" = 0 ]; then break; fi
echo 'SCREEN: prone image - re-rolling the ceremony (the -R destroy above clears the'
echo '        clones the failing screen fiddles leaked, which would block the re-snapshot)'

done
[ "$screen_bad" = 0 ] || echo 'SCREEN FAILED: 4 prone images in a row - do NOT ship this build'


out=$(echo '["select @@version"]' | /mnt/fire/sqlserver_2019l/run.sh) || true
printf '%s\n' "$out"
# run.sh has no meaningful exit status: assert on the body
[ -n "$out" ] || { echo "ABORT: verification fiddle returned an empty body"; exit 1; }
