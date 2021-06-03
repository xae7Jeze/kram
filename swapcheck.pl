#!/usr/bin/env perl

# Checking for Swap-Usage according to this metric
# https://www.suse.com/communities/blog/sles-1112-os-tuning-optimisation-guide-part-1/

open(F, '</proc/meminfo') or die "Cannot open /proc/meminfo\n";
while(<F>){
  ($k,$v,undef) = split;
  $k =~ /(?:SwapTotal|Inactive\(anon\)|SwapFree):/ or next;
  $e->{$k}=$v;
}
close F;

$su = $e->{'SwapTotal:'} - $e->{'SwapFree:'};
$ia = $e->{'Inactive(anon):'};

$diff = ($ia - $su);
$st = $diff >= 0 ? "GOOD" : "BAD";

printf "%s: SwapUsed: %d kB InactiveAnon: %d kB Diff: %d kB\n", $st, $su, $ia, $diff ;
