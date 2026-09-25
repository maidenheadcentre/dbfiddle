#!/bin/bash
# Regenerate the BODY of adventureworks/instawdb.linux.sql from Microsoft's upstream
# instawdb.sql. Run this only when refreshing to a NEW upstream AdventureWorks release;
# afterwards re-pin aw.zip.sha256, re-attach the header comment block (kept in the committed
# instawdb.linux.sql), and review the diff.
#
#   ./derive.sh /path/to/upstream/instawdb.sql > body.sql
#
# Amendments applied (see the header of instawdb.linux.sql for the full rationale):
#   1-2. strip the CREATE FULLTEXT catalog + indexes and the freetext demo proc
#        [dbo].[uspSearchCandidateResumes] - full-text search isn't on SQL Server for Linux.
#   3.   drop CODEPAGE='65001' from every BULK INSERT - unsupported on Linux; the UTF-8 CSVs
#        load correctly without it (Linux's bulk default codepage is UTF-8).
#   4.   drop the BULK INSERT of Production.Document + Production.ProductDocument - their
#        binary Word-doc varbinary has embedded tabs the char-delimited BULK INSERT can't parse.
#   5.   template the source-data-path :setvar to __DATAPATH__ (install.sh substitutes it).
#   6.   strip upstream's UTF-8 BOM - this body is concatenated after the header comment, so a
#        BOM would sit mid-file where sqlcmd reads it as data and fails with Msg 102.
#   7.   drop the ACCELERATED_DATABASE_RECOVERY clause and the SET OPTIMIZED_LOCKING statement
#        that requires it - neither is available in Express, and ADR takes the whole ALTER
#        DATABASE (RECOVERY SIMPLE, READ_COMMITTED_SNAPSHOT) with it when it fails. Both are
#        anchored on their exact text and asserted below, so an upstream reword is a loud
#        failure rather than a silently un-applied amendment.
set -euo pipefail
awk '
  /CREATE FULLTEXT/ || /CREATE PROCEDURE \[dbo\]\.\[uspSearchCandidateResumes\]/ { skip=1 }
  /BULK INSERT \[Production\]\.\[(Document|ProductDocument)\]/ { skipb=1 }
  skip && /^GO[[:space:]]*$/ { skip=0; next }
  skipb && /^\)/ { skipb=0; next }
  !skip && !skipb { print }
' "$1" | grep -v "CODEPAGE = '65001'," \
  | sed 's|:setvar SqlSamplesSourceDataPath.*|:setvar SqlSamplesSourceDataPath "__DATAPATH__"|' \
  | perl -pe 's/^\xEF\xBB\xBF// if $. == 1' \
  | perl -0777 -pe 'my $a = s/,(\r?\n\s*)ACCELERATED_DATABASE_RECOVERY = ON;/;/g;
                    my $o = s/ALTER DATABASE \$\(DatabaseName\)\r?\nSET OPTIMIZED_LOCKING = ON;\r?\nGO\r?\n\r?\n//g;
                    die "derive.sh: amendment 7 did not apply (ADR=$a, OPTIMIZED_LOCKING=$o,\n".
                        "expected 1 each) - upstream changed shape; re-check by hand\n"
                        unless $a == 1 && $o == 1' \
  | perl -0777 -pe '
      # amendment 8 - load the CSVs as UTF-16 instead of as 8-bit char data.
      # Amendment 3 has to remove CODEPAGE = 65001 because SQL Server rejects the option
      # outright on Linux ("Msg 16202 ... not supported on the Linux platform"), and on
      # SQL Server 2025 that is harmless because its BULK INSERT already defaults to UTF-8.
      # SQL SERVER 2022 DOES NOT. It falls back to the server code page (1252 here), so
      # every non-ASCII byte arrives as mojibake - AdventureWorks row 1 loads as
      # "S<box>nchez" instead of "Sanchez" - and rows that then overflow their column push
      # the load past its 10-error limit, so sqlcmd -b aborts and every table after
      # Production.ProductPhoto is left EMPTY. That failure is quiet: the tables all exist,
      # so an AW-TABLES count still passes.
      # Measured on a throwaway guest rather than guessed (bulkprobe.sh on cumbria2): a
      # UTF-8 collation on the target column does not help, FORMAT=CSV does not help, and
      # widechar WITHOUT a byte-order mark fails with "Cannot fetch a row from OLE DB
      # provider BULK". UTF-16LE WITH a BOM and wide terminators is the spelling that works.
      # install.sh does the matching iconv; the two halves must stay in step.
      my %n;
      $n{d} = s/DATAFILETYPE = .char./DATAFILETYPE = q{widechar}/g;
      # terminators are matched against the file, so in a UTF-16 file they are wide too;
      # spell them as hex bytes, because the plain forms are what the probe showed failing
      $n{ft} = s/FIELDTERMINATOR ?= ..t./FIELDTERMINATOR = q{0x0900}/g;
      $n{fp} = s/FIELDTERMINATOR ?= .\+\|./FIELDTERMINATOR = q{0x2b007c00}/g;
      $n{rh} = s/ROWTERMINATOR ?= .0x0a./ROWTERMINATOR = q{0x0a00}/g;
      $n{ra} = s/ROWTERMINATOR ?= .&\|\\n./ROWTERMINATOR = q{0x26007c000a00}/g;
      $n{rn} = s/ROWTERMINATOR ?= ..n./ROWTERMINATOR = q{0x0a00}/g;
      s/q\{([^}]*)\}/'"'"'$1'"'"'/g;
      my @want = (d=>66, ft=>53, fp=>13, rh=>48, ra=>13, rn=>5);
      while (my ($k,$v) = splice @want, 0, 2) {
        die "derive.sh: amendment 8 did not apply as expected ($k=$n{$k}, wanted $v)\n".
            "upstream changed the BULK INSERT terminators; re-derive the counts by hand\n"
            unless $n{$k} == $v;
      }'
