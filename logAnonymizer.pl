#!/usr/bin/env perl

# logAnonymizeR.pl - Anonymize ip addresses in
# logfiles
#
#

my $VERSION="0.20210603.0";

use strict;
use warnings;
use v5.10;
use English '-no_match_vars';
use File::Temp qw/tempfile/;
use File::Spec;
use File::Find;
use Getopt::Long;
use IO::Uncompress::Gunzip qw/gunzip $GunzipError/;
use IO::Compress::Gzip qw/gzip $GzipError/;
use Storable qw/lock_store lock_retrieve/;
use Socket qw/inet_pton AF_INET6 AF_INET/;

# make %ENV safer
delete @ENV{qw(IFS CDPATH ENV BASH_ENV PATH)};
# set PATH to some reasonable secure value
$ENV{PATH}="/bin:/sbin:/usr/bin:/usr/sbin";
# set File::Temp seclevel to high
File::Temp->safe_level( File::Temp::HIGH );

sub usage($);
sub anonymize_v4($$);
sub anonymize_v6($$);
sub anonymize_lf($$$$$);
sub find_logs();
sub open_db($$);
sub cleanup_db ($$);
sub store_db($$$);

our (
  $me, $days, $dbdir, $dbuser, $v4parts, $v6parts,$instance,
  $prefix, $prefix_re, $daysindb, $defaults, $help, $debug
);
my ($db, $dir, $lock, $path, $secsindb, $dbfile, $recurse, $um);

$me = $0;
$me =~ s|^.*/||;
$days = -1;
$prefix = $defaults->{prefix} = [];
$prefix_re = [];
$dbdir = $defaults->{dbdir} = '/var/cache/anonymizer';
$dbuser = $defaults->{dbuser} = 'anonymizer';
$instance = $defaults->{instance} = 'default';
$daysindb = $defaults->{daysindb} = 100;
$v4parts = $defaults->{v4parts} = 3;
$v6parts = $defaults->{v6parts} = 3;
$path = undef;
$lock = undef;
$db = undef;
unless(&GetOptions(
    "debug" => \$debug,
    "help" => \$help,
    "days=i" => \$days,
    "v4parts=i" => \$v4parts,
    "v6parts=i" => \$v6parts,
    "daysindb=i" => \$daysindb,
    "prefix=s@" => \$prefix,
    "dbuser=s" => \$dbuser,
    "instance=s" => \$instance,
    "dbdir=s" => \$dbdir
  )) {
  usage(1);
}

if($help){
  usage(0);
}

$secsindb = $daysindb * 24 * 3600;

if(
  ($v4parts < 0) or ($v6parts < 0) or ($v4parts > 4) or 
  ($v6parts > 8) or ($daysindb < 1) or ($days < 1)){
  usage(1);
}

map {
  ($_ !~ /^[a-z][a-z_0-9.-]{0,60}[a-z0-9]$/i) and usage(1);
  push @$prefix_re, quotemeta($_); 
} @$prefix;

($instance !~ /^[a-z][a-z_0-9]{0,60}[a-z0-9]$/i) and usage(1);

$dbfile=join('/',$dbdir,"${instance}_processed.db");

$prefix_re  = (scalar(@$prefix_re) > 0) ? join ('|', @$prefix_re) : "";

use sigtrap qw(die normal-signals error-signals);

# Open db to keep information about already processed logs
# Key = DEVNO_INO_SIZE_MTIME, Value=UnixTimeStamp

$db = open_db($dbfile, $dbuser);
unless (defined($db)){
  print STDERR "$me: WARN: Opening state dbfile '$dbfile' failed. Won't keep state\n";
}

# Run only once, to avoid races
(-e ("${dbfile}.LCK") and ! -f ("${dbfile}.LCK")) and die "$me: ERROR: Lockfile exists and is no plain file\n";
(-f ("${dbfile}.LCK") and -s("${dbfile}.LCK")) and die "$me: ERROR: Lockfile exists and is not empty\n";
$um = umask (0077);
unless (open ($lock,">>${dbfile}.LCK")) {
  $lock = undef;
  umask($um);
  die "$me: ERROR: Opening Lockfile failed\n";
}
umask($um);
unless (flock ($lock,2+4)){
  close($lock);
  undef($lock);
  die "$me: ERROR: Instance '$instance' already running ...\n";
}

#
# Loop over all remaining arguments, find logs and process them with anonymize_lf
#

foreach $path (@ARGV) {
   unless(
     ( -d "${path}" and -r "${path}" and -x "${path}") or 
     ( -f "${path}" and -r "${path}" and -w "${path}")
   ){
    print STDERR "$me: ERROR: Path '$path' doesn't exist or is neither a file nor a directory.\n";
    next;
  }

  $recurse = (-d $path) ? 1 : 0 ;
  if($recurse and (scalar(@$prefix) == 0)){
    print STDERR "$me: ERROR: No prefix given\n";
    exit 2;
  }

  if ($debug){
    if($recurse){
      print STDERR "$me: DEBUG: Looking for files prefixed '" . join (',', @$prefix) . "' older than $days days below '$path' to process\n";
    } else {
      print STDERR "$me: DEBUG: Processing file '$path' regardless of prefix\n";
    }
  }
  find(\&find_logs, $path);
}

sub find_logs(){
  my($mtime, $to);
  -f ($_) or return;
  -r ($_) or return;
  -w ('.') or return;
  -w ($_) or return;
  if($recurse){
    /^(?:${prefix_re})(?:[._-]|$)/ or return;
  }
  (int(-M($_)) < $days) and return;
  $debug and print STDERR "$me: DEBUG: Processing $File::Find::dir/$_\n";
  if (anonymize_lf($_, $v4parts, $v6parts, $db, $secsindb)){
    $debug and print STDERR "$me: DEBUG: Processing $File::Find::dir/$_ done\n";
  } else {
    print STDERR "$me: Anonymize $File::Find::dir/$_ failed\n";
  }
}

if(defined($db)){
  cleanup_db($db, $secsindb);
  unless (store_db($db, $dbfile, $dbuser)){
    print STDERR "$me: Storing db to '$dbfile' failed\n";
  }
}
exit 0;

#
# Arg1: V4 Address
# Arg2: Parts that should be preserved
#   e.g (1.2.3.4, 3) results in 1.2.3.0
#

sub anonymize_v4($$){
  my ($in,$parts);
  ($in,$parts) = @_;
  inet_pton(AF_INET,$in) or return $in;
  local $_;
  $parts <= 0 and return $in;
  my @a = split (/\./,$in);
  (scalar(@a) != 4) and return $in;
  map{
    unless ($_ =~ /^\d+$/){
      return $in;
    }
    if ($_ < 0 or $_ > 255){
      return $in;
    }
  } @a;
  $parts > 3 and return $in;
  for(my $i = $parts; $i < 4; $i++){
    $a[$i] = 0;
  }
  my $av4 = join('.',@a);
  return $av4;
}





#
# Arg1: V6 Address
# Arg2: Parts that should be preserved
#   e.g (1:2:3:4:5:6:7:8, 3) results in 1:2:3::
#

sub anonymize_v6($$){
  my ($in,$parts);
  ($in,$parts) = @_;
  inet_pton(AF_INET6,$in) or return $in;
  local $_;
  $parts <= 0 and return '';
  $parts--;
  my @a = split (/:/,$in,-1);
  ((scalar(@a) < 3) or (scalar(@a) > 8)) and return $in;
  ($in =~ m/[^:]:$/) and return $in;
  ($a[0] eq '')  and  $a[0] = "0";
  ($a[-1] eq '')  and  $a[-1] = "0";
  my $i = 0;
  map{
    ($_ eq '') and $i++;
      ($_ =~ /^[\da-f]*$/i) or return $in;
  } @a;
  ($i > 1) and return $in;
  $parts > 7 and return $in;
  my $mo = 8 - scalar(@a);
  my(@nv6);
  # expand v6 ip
  map{
    if ($_ eq ''){
      while($mo-- >= 0){
        push(@nv6,"0");
      }
    }else {
      push @nv6,$_;
    }
  } @a;
  # shorten to first $parts+1 parts
  my $av6=join(':',@nv6[0..$parts]);
  if ($parts == 6) {
    $av6 .= ":0";
  } elsif ($parts < 6){
    $av6 .= "::";
  }
  # remove leading zeros
  while ($av6 =~ s/(^|:)0/$1/){}
  # remove additional invalid colons
  $av6 =~ s/:::+/::/g;
  return $av6;
}

# 
# anonymizes lines in logfiles, if first item is an ip address
# arg[0] = logfile
# arg[1] = Parts to keep from v4 addresses
# arg[2] = Parts to keep from v6 addresses
# arg[3] = State database
# arg[4] = Consider entries older than arg[4] seconds as stale
#
sub anonymize_lf($$$$$){
  my (
    $from, $to, $f_from, $f_to, $fn, $dn, $gz, $key, $x, $r, $v4p, $v6p,
    $re4, $re6, $z, $dbtimeout
  );
  my(@l,@stat);
  ($from, $v4p, $v6p, $db, $dbtimeout) = @_;
  local $_;
  unless(-f $from and -r $from){
    return(0);
  }
  @stat = lstat($from);
  my $oldkey = join ("_", @stat[0..1]);
  $key = join ("_", (@stat[0..1],@stat[7,9]));
  if(defined($db->{$oldkey})){
    $debug and print STDERR "$me: DEBUG: Converting old keyformat '$oldkey' to new keyformat '$key'\n";
    defined($db->{$key}) or $db->{$key} = $db->{$oldkey};
    delete($db->{$oldkey});
  }
  if (defined ($db->{$key})){
    if (($db->{$key} =~ /^\d+$/) and  ($db->{$key} >= (time()-($dbtimeout)))){
      $debug and 
        print STDERR ("$me: DEBUG: File '", $File::Find::dir ,
          "/$from' was already processed: Ignoring\n");
      return 2;
    } else {
      $debug and print STDERR "$me: DEBUG: Deleting invalid or stale key '$key' ($db->{$key})\n";
      delete($db->{$key});
    }
  }
  ($fn, $dn) = File::Spec->splitpath($from);
  if($dn eq ''){
    $dn='.';
  }
  eval {($f_to, $to) = tempfile( DIR => $dn, UNLINK => 1)};
  if($@){
    chomp $@;
    print STDERR "$me: ERROR: Creating tempfile failed: '$@'\n";
    return(0);
  }
  $gz = 0;
  if($from =~ /\.gz$/){
    $gz = 1;
  }
  if($gz){
    $debug and  print STDERR "$me: DEBUG: Processing gzipped file '$File::Find::dir/$from'\n";
    unless (
      ($f_from = new IO::Uncompress::Gunzip ($from, AutoClose => 1)) and
      ($f_to = new IO::Compress::Gzip ($f_to, AutoClose => 1))
    ){
      print STDERR "$me: ERROR: Opening gzipped in ($from) and/or output file ($to) in '$File::Find::dir' failed\n";
      return(0);
    }
  } else {
    $debug and  print STDERR "$me: DEBUG: Processing file '$File::Find::dir/$from'\n";
    unless (open($f_from,'<',$from)){
      print STDERR "$me: ERROR: Opening input file '$File::Find::dir/$from' failed\n";
      return(0);
    }
  }
  if(-l $from or -l $to){
    print STDERR "$me: WARN: Refusing to process symlinks ('$File::Find::dir/$from' or '$File::Find::dir/$to')\n";
    close($f_to);
    close($f_from);
    return 0;
  }
  $f_to->autoflush(1);
  $re4 = qr/\b((\d+)\.(\d+)\.(\d+)\.(\d+))\b/;
  $re6 = qr/\b([\da-f:]+)\b/;
  while(<$f_from>){
    s/$re4/anonymize_v4($1,3)/ge;
    s/IPv6:/IPv6: /g;
    s/$re6/anonymize_v6($1,3)/ge;
    s/IPv6: /IPv6:/g;    
    unless (print $f_to $_) { 
      print STDERR "$me: ERROR: Writing output file '$File::Find::dir/$to' failed\n";
      close($f_to);
      close($f_from);
      return 0;
    }
  }
  close($f_from);
  close($f_to);
  if(-l $from or -l $to){
    print STDERR "$me: WARN: Refusing to process symlinks ('$File::Find::dir/$from' or '$File::Find::dir/$to')\n";
    return 0;
  }
  chmod (($stat[2] & 07777), $to);
  chown ($stat[4], $stat[5], $to);
  utime ($stat[8], $stat[9], $to);
  unless (rename($to, $from)){
    print STDERR "$me: ERROR: Renaming '$File::Find::dir/$to' -> '$File::Find::dir/$from' failed\n";
    return 0;
   }
  unless (@stat = lstat($from)){
    print STDERR "$me: ERROR: Cannot stat '$File::Find::dir/$from' failed\n";
    return 0;
  }
  if(defined($db)){
    $key = join ("_", (@stat[0..1],@stat[7,9]));
    $db->{$key} = time();
    $debug and print STDERR "$me: DEBUG: Adding '$key' ($db->{$key}) to state database\n";
  }
  return 1;
}

#
# opens database to store state information
# about already processed files. Creates file
# if needed
# arg[0] = dbfile
# arg[1] = user to open dbfile
#
# returns reference to hash $db or undef in error
#
#

sub open_db($$){
  my ($db, $f_db, $u, $uid, $gid, $saved_uid, $saved_gid);
  ($f_db, $u) = @_;
  $db = undef;
  ($uid,$gid) = (getpwnam($u))[2,3];
  unless(defined ($uid) and ($uid > 0)) {
    print STDERR "$me: ERROR: User '$u' doesn't exist or has uid 0\n";
    return undef;
  }
  unless(defined ($gid) and ($gid > 0)) {
    print STDERR "$me: ERROR: Group of '$u' doesn't exist or has gid 0\n";
    return undef;
  }
  $saved_gid=$EGID;
  $saved_uid=$EUID;
  $EGID=join (' ', $gid, $gid);
  $EUID=$uid;
  if ($EUID != $uid){
    $EGID=$saved_gid;
    $EUID=$saved_uid;
    print STDERR "$me: ERROR: Dropping privs to open state db as '$u' failed\n";
    return undef;
  }

  if(-f $f_db) {
    eval{$db=lock_retrieve($f_db);};
    if ($@) {
      $EGID=$saved_gid;
      $EUID=$saved_uid;
      print STDERR "$me: ERROR: Opening db in '$f_db' failed\n";
      return undef;
    }
    $EGID=$saved_gid;
    $EUID=$saved_uid;
    $debug and print STDERR "$me: DEBUG: Opened state database from '$f_db'\n";
    return $db;
  }
  eval{
    my $um = umask (0077);
    $db={};
    lock_store($db,$f_db);
    umask ($um);
  };
  if($@){
    $EGID=$saved_gid;
    $EUID=$saved_uid;
    print STDERR "$me: ERROR: creating new state db in '$f_db' failed\n";
    return undef;
  }
  $EGID=$saved_gid;
  $EUID=$saved_uid;
  $debug and print STDERR "$me: DEBUG: Created new state database in '$f_db'\n";
  return $db;
}

#
# remove entries older than arg[1] days from database
# arg[0] = dbhash
# arg[1] = time limit in secs
#
#

sub cleanup_db ($$){
  my($db, $timeout, $limit);
  ($db, $timeout) = @_;
  $limit = time() - $timeout;
  $debug and print STDERR "$me: DEBUG: Removing entries older than $timeout secs from state database\n";
  map{
    if ($db->{$_} !~ /^\d+$/) {
      $debug and print STDERR "$me: DEBUG: Removing invalid entry '$_' ($db->{$_})from state database\n";
      delete($db->{$_});
    } elsif ($db->{$_} < $limit) {
      $debug and print STDERR "$me: DEBUG: Removing stale entry '$_' ($db->{$_})from state database\n";
      delete($db->{$_});
    }
  } keys(%$db);
}

#
# saves hash $db to dbfile
# arg[0] = dbhash
# arg[1] = dbfile
# arg[2] = user to open dbfile
#
# returns 1 on success, 0 on error
#
#

sub store_db($$$) {
 my($db, $f_db,$u,$uid,$gid,$saved_uid,$saved_gid);
 ($db, $f_db,$u)=@_;
 ($uid,$gid) = (getpwnam($u))[2,3];
  unless(defined ($uid) and ($uid > 0)) {
    print STDERR "$me: ERROR: User '$u' doesn't exist or has uid 0\n";
    return undef;
  }
  unless(defined ($gid) and ($gid > 0)) {
    print STDERR "$me: ERROR: Group of user '$u' doesn't exist or has gid 0\n";
    return undef;
  }
  $saved_gid=$EGID;
  $saved_uid=$EUID;
  $EGID=join (' ', $gid, $gid);
  $EUID=$uid;
  if ($EUID != $uid){
    $EGID=$saved_gid;
    $EUID=$saved_uid;
    print STDERR "$me: ERROR: Dropping privs to store state db as '$u' failed\n";
    return undef;
  }

  eval{lock_store($db,$f_db);};
  $EGID=$saved_gid;
  $EUID=$saved_uid;
  if($@){
    print STDERR "$me: ERROR: Failed to store state db to: '$f_db'\n";
    return 0;
  }
  $debug and print STDERR "$me: DEBUG: Stored state db to: '$f_db'\n";
  return 1;
}

#
# Usage hint
# arg[0] = Exitcode
#


sub usage($) {
  print STDERR 
    "\nUSAGE:\n $me [ --debug --instance <INSTANCE> --dbuser <DBUSER> --dbdir <STATUS_DIR> --daysindb <DAYS> --v4parts <DOT_SEPARATED_PARTS> --v6parts <COLON_SEPARATED_PARTS> ] --prefix <PREFIX> --days <DAYS> <files_or_dirs_to_process ...>\n",
    "  Process files named <PREFIX>* with mtime greater <DAYS>\n",
    "  Preserve <PARTS> of IP when anonymizing. Defaults are: v4: $defaults->{v4parts}, v6: $defaults->{v6parts}\n",
    "  Script runs only once per <INSTANCE> (Default: $defaults->{instance})\n",
    "  If processed argument is a directory: recurse\n",
    "  If it's a file just anonymize it regardless of <PREFIX>\n\n",
    "Hints:\n",
    "- When recursing $me looks for files named '<PREFIX> and <PREFIX>[._-]*'\n",
    "- --prefix could be given more than once to look for multiple prefixes\n",
    "- Skript keeps information about already processed files in <STATUS_DIR> (Default: $defaults->{dbdir})\n",
    "  Information will be kept for <DAYS> (Default: $defaults->{daysindb})\n",
    "  DB will be opened as user <DBUSER> (Default: $defaults->{dbuser})\n",
    "Version: $VERSION\n\n";
  exit $_[0];
}

# Remove lock
END {
  eval {
    if(defined($lock)){
      my @ls = stat($lock);
      my @fs = lstat("${dbfile}.LCK");
      if (($ls[0] == $fs[0]) and ($ls[1] == $fs[1]) and 
          -f("${dbfile}.LCK") and (-s("${dbfile}.LCK") == 0)){
        $debug and print STDERR "$me: DEBUG: Unlinking Lockfile: '${dbfile}.LCK'\n";
        unlink("${dbfile}.LCK");
      }
      flock($lock,8);
      close($lock);
    }
  }
}


# vim:sw=2:ts=2:ai:et:ic
