#!/usr/bin/env perl
use warnings;
use strict;

sub quote_all_fields($);

# safety settings
delete @ENV{qw(IFS CDPATH ENV BASH_ENV PATH)};
# set PATH to some reasonable secure value
$ENV{PATH} = "/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin";

my $line_started = 0;
my $line_completed=0;
my $line = "";
my $cur_line = "";

for (my $i = 0;$cur_line=<>;$i++){
  chomp ($cur_line);
  $cur_line =~ tr /\r//d;

  if ($i == 0) {
    if ($cur_line =~ m/^Date,/){
      print "$cur_line\n";
      next;
    }
  }
  if ($cur_line =~ /^\d/){
    if ($line eq ""){
      $line = $cur_line;
    } else {
      print quote_all_fields($line);
      $line = $cur_line;
    }
  } elsif ($cur_line =~ /^\s/){
    if ($line ne "") {
      $cur_line =~ s/^\s*/ /;
      $line = "$line $cur_line";
    } else {
      print STDERR "ERROR: Invalid line. Ignoring\n";
      next;
    }
  } else {
    print STDERR "ERROR: Invalid line. Ignoring\n";
    next;
  }
}

if ($line ne "") {
  print quote_all_fields($line);
}

sub quote_all_fields($){
  my ($l, $date, $mid, $host, $sender, $r, $already_quoted, $recipient, $subject, $last_state);
  $l = shift;
  chomp($l);
  $l =~ tr /\r//d;
  ($l =~ m/^([^,]+),([^,]+),([^,]+),([^,]+),(.+)$/) or return "$l";
  $date = '"' . $1 . '"';
  $mid= '"' . $2 . '"';
  $host= '"' . $3 . '"';
  $sender= '"' . $4 . '"';
  $r=$5;
  $already_quoted = ($r =~ /^"/) ? 1 : 0;
  if ($already_quoted){
    $r =~ s/^("[^"]*"),//;
    $recipient = $1 ;
  } else {
    $r =~ s/^([^,]*),//;
    $recipient = '"' . $1 . '"';
  }
  $already_quoted = ($r =~ /^"/) ? 1 : 0;
  if ($already_quoted){
    $r =~ s/^(".*"),//;
    $subject = $1 ;
  } else {
    $r =~ s/^([^,]*),//;
    $subject = '"' . $1 . '"';
  }
  $already_quoted = ($r =~ /^"/) ? 1 : 0;
  if ($already_quoted){
    $r =~ s/^(".*")\s*$//;
    $last_state = $1 ;
  } else {
    $r =~ s/^([^,]*)\s*$//;
    $last_state = '"' . $1 . '"';
  }
  return "$date,$mid,$host,$sender,$recipient,$subject,$last_state\n";
}
