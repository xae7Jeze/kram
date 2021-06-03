#!/usr/bin/perl -w

BEGIN {
  use strict;
  use Getopt::Std;
  use Data::Dumper;
  use FileHandle;
  use File::Temp qw/tempfile/;
  use IPC::Open2;
  use POSIX qw(:termios_h);
  # make %ENV safer
  delete @ENV{qw(IFS CDPATH ENV BASH_ENV PATH)};

  # set PATH to some reasonable secure value
  $ENV{PATH} = "/bin:/sbin:/usr/bin:/usr/sbin";
  use English '-no_match_vars';
  our ($term, $c_lflags,$fd_stdin,$opts,$myname,$usage,$saved_umask);
  my ($files,$i);
  sub gen_pkcs12($);
  sub get_friendly_names($);
  sub check_openssl();

  $myname=$0;
  $myname=~s|^.*/||;
  $usage="Usage: $myname -c <crt_file> -k <key_file> -a <ca_file> -p <pkcs12_outfile>";
  $saved_umask = umask(0077);
  $fd_stdin = fileno(STDIN);
  $term = POSIX::Termios->new();
  $term->getattr($fd_stdin);
  $c_lflags = $term->getlflag();
  sub reset_term(){
    $term->setlflag($c_lflags);
    $term->setcc(VTIME, 0);
    $term->setattr($fd_stdin, TCSANOW);
   }

  sub echo_off(){
    my($echo, $noecho);
    $echo = ECHO | ECHOK | ICANON;
    $noecho = $c_lflags & ~$echo;
    $term->setlflag($noecho);
    $term->setlflag($c_lflags & ~(ECHO | ECHOK | ICANON));
    $term->setcc(VTIME, 1);
    $term->setattr($fd_stdin, TCSANOW);
    }

  sub getpw () {
    my($buf,$pw);
    &echo_off();
    print "Please enter PW for Key and PKCS12-Structure: ";
    while (read (STDIN, $buf, 1) == 1) {
      if ($buf eq "\r") { print "\r" ; next ; }
      if ($buf eq "\n") { print "\n"; last ;  }
      print '*';
      $pw.=$buf;
      }
    &reset_term();
    return ${pw}
 }

}

END {
    &reset_term();
    umask($saved_umask);
}

defined(&check_openssl()) or die "$myname: openssl not found in PATH ($ENV{PATH})\n";

$opts={};
getopts('c:k:a:p:', $opts) or die "$usage\n";

$files->{f_crt} = $opts->{c};
$files->{f_key} = $opts->{k};
$files->{f_ca} = $opts->{a};
$files->{f_p12} = $opts->{p};

for $i ('f_crt','f_key','f_ca'){
  (defined ($files->{$i})) or die "$usage\n";
  ($files->{$i} eq "" ) and die "$usage\n";
  (-s $files->{$i}) or die "$usage\n";
  }
(defined($files->{f_p12}) and ($files->{f_p12} ne '')) or die "$usage\n";
(-e $files->{f_p12}) and die "$myname: $files->{f_p12} already exists. Won't overwrite\n";
defined(&gen_pkcs12($files)) or die "$myname: generating pkcs12 file failed\n";
exit 0;

sub get_friendly_names($){
   my ($buf,$f,$fns,$crts,$r,$w,$pid,$s);
   $f=shift;
   $fns=[];
   $crts=[];
   open F, "<$f" or return undef;
   $buf=join "",<F>;
   close F;
   @$crts= $buf =~ /(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----\r?\n?)/gs;
   map {
        $r=FileHandle->new;
        $w=FileHandle->new;
        $r->autoflush(1);
        $w->autoflush(1);
        $pid = open2($r, $w, ('openssl', 'x509', '-subject', '-noout'));
        print $w "$_\n";
        $s= join "", <$r>;
        $s =~ s|^.*CN=||;
        $s =~ tr/ \t/__/;
        $s =~ s|\*|wildcard|g;
        chomp ($s);
        push @$fns,$s;
        $r->close();
        $w->close();
        } @$crts;
  return ($fns);
  }

sub gen_pkcs12($){
   my ($buf,$f,$ftmp,$fh,$f_crt,$f_key,$f_ca,$f_p12,$crt_friendly,$pw);
   my (@canames);
   $f_crt = $_[0]->{f_crt};
   $f_key = $_[0]->{f_key};
   $f_ca = $_[0]->{f_ca};
   $f_p12 = $_[0]->{f_p12};
   ($fh, $ftmp) = tempfile("crypt_keyf_XXXXXXXX", UNLINK => 1, DIR => ($ENV{TMPDIR} || "/tmp"));
   $crt_friendly=&get_friendly_names($f_crt)->[0];
   (defined($crt_friendly) and ($crt_friendly ne '')) or return undef;
   @canames=();
   map {
	push @canames, ('-caname',$_);
	} @{&get_friendly_names($f_ca)};
   (@canames == 0) and  return undef;
   open SV_ERR, ">&STDERR";
   close STDERR;
   $pw=&getpw();
   open (F, '|-', 'openssl', 'rsa' , '-aes256', '-passout', 'stdin', '-in' , $f_key, '-out',$ftmp) or return undef;
   open STDERR, ">&SV_ERR";
   close SV_ERR;
   print F $pw;
   close F;
   open (F, '|-', 'openssl', 'pkcs12', '-passin', 'stdin', '-passout', 'stdin', '-export', '-in', $f_crt,
       '-inkey', $ftmp, '-out', $f_p12, '-name', $crt_friendly,
       '-certfile', $f_ca, @canames) or return undef;
   print F "$pw\n$pw"; 
   close F;
   return 1;
  }

sub check_openssl(){
   map{ (-f $_ . "/openssl") and (-x $_ . "/openssl") and return ($_ . "/openssl"); } split (/:/,$ENV{'PATH'});
   return undef;
   }

