#!/usr/bin/perl
# Host side of the vsock exchange, shared by every snapshot engine and deployed to
# /mnt/fire/listener.pl by deploy.sh. run.sh invokes it by that absolute path, so it is
# read live per request - a change here takes effect on the next fiddle, with no rebuild,
# and no engine's @base can carry a stale copy. It is deliberately NOT written by any
# engine recipe: a recipe that wrote it would clobber the shared copy for every engine on
# the next rebuild of any one of them, which is why no recipe writes vmlinux-* either.
#
# The guest LISTENS and this dials in: seed, now and batches go out over three
# connections to port 9001, then output.json comes back on 9002. Exiting is the
# "response ready" signal run.sh waits on.
use strict;
use IO::Socket::UNIX;
my ($root, $seedf, $nowf, $batchf, $outf) = @ARGV;
my $uds = "$root/v.sock";

# Memory bound, NOT the user-facing size policy. A guest is untrusted and root inside it
# is assumed, so the host counts bytes itself rather than believing anything the guest
# says about length. This sits ABOVE the dispatcher's 2.5MB policy on purpose: the
# dispatcher is what decides 413, and it can only do that if a body over its own limit
# actually reaches it. So bodies below 2.5MB are always complete, and a truncated one -
# which can only start above 5MB - is over the dispatcher's limit long before it gets
# here, and is rejected on size before anything tries to parse it.
my $CAP = 5 * 1024 * 1024;

sub slurp { open my $f, "<", $_[0] or die "$_[0]: $!"; binmode $f; local $/; my $d = <$f>; close $f; $d }

sub dial {
  my ($port) = @_;
  my $end = time + 65;
  while (time <= $end) {
    my $c = IO::Socket::UNIX->new(Peer => $uds);
    if ($c) {
      binmode $c;
      print $c "CONNECT $port\n";
      my $line = <$c>;
      return $c if defined $line && $line =~ /^OK /;
      close $c;
    }
    select undef, undef, undef, 0.005;
  }
  die "vsock dial timeout";
}

for my $payload (slurp($seedf), slurp($nowf), slurp($batchf)) {
  my $c = dial(9001);
  print $c $payload;
  close $c;
}

my $c = dial(9002);
my ($out, $n) = ('', 0);
while (1) {
  # read(), NOT sysread(): dial() consumes the "OK" line with <$c>, which fills perl's
  # 8K IO buffer, and sysread bypasses that buffer - silently discarding whatever the
  # guest sent in the same write as the handshake. A body smaller than the readahead
  # vanishes entirely, which is an empty output.json and a 502. See test/repro.py.
  my $r = read($c, my $buf, 65536);
  last unless defined $r && $r > 0;
  $n += $r;
  last if $n > $CAP;    # stop reading and close: a hostile guest gets no more of our heap
  $out .= $buf;
}
close $c;

open my $f, ">", $outf or die "$outf: $!";
binmode $f;
print $f $out;
close $f;
