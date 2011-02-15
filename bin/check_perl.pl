#!/usr/bin/perl
use ExtUtils::MakeMaker "!prompt";
use File::Copy;
use strict;
$^W = 1;
$|  = 1;
use Carp;
use Config;

my ($ok, %have) = check_prereq
  (
   'JavaScript::Minifier' => [0,  1],
  );

exit;

#### Subroutines

sub check_prereq {
  my (%have, @mods_needed, $i, $need, $ok, $pkg, $ver);
  $ok = 1;

  while (($pkg, $ver) = splice(@_, 0, 2)) {
    ($ver, $need) = ($ver->[0], $ver->[1]);
    if (have_vers($pkg => $ver)) {
      $have{$pkg} = 1;
    }
    else {
      if ($need) {
        $ok = 0;
        push @mods_needed, $pkg;
        if ($ver == 0) {
          print "**** Majordomo requires the $pkg module, any version.";
        }
        else {
          print "**** Majordomo requires the $pkg module, version $ver or greater!\n";
        }
      }
    }
  }
  if (@mods_needed) {
    print "\n\nSome modules which Majordomo requires were not found.

If the CPAN module is not supported on your system, you can locate the
modules by visiting http://search.cpan.org/ with your WWW client.

Otherwise, you can install them by running the following commands as
root or another user capable of installing modules:

";

    for $i (@mods_needed) {
      print "perl -MCPAN -e'CPAN::Shell->install(\"$i\")'\n";
    }
    print "\n";
  }

  ($ok, %have);
}

# This was originally clipped from the libnet Makefile.PL.
sub have_vers {
  my($pkg, $wanted, $msg, $vnum, $vstr) = @_;
  no strict 'refs';
  printf("Checking for %17s %-9s ", $pkg, $wanted==0?'(any)':"(v$wanted)");

  eval { my $p; ($p = $pkg . ".pm") =~ s!::!/!g; require $p; };

  $vnum = ${"${pkg}::VERSION"} || ${"${pkg}::Version"} || 0;
  $vnum = -1 if $@;

  if ($vnum < 0) {
    $vstr = "not found";
  }
  elsif ($vnum > 0) {
    $vstr = "found v$vnum";
  }
  else {
    $vstr = "found unknown version";
  }

  print (($vnum >= $wanted ? "ok: " : " "), "$vstr\n");
  $vnum >= $wanted;
}
