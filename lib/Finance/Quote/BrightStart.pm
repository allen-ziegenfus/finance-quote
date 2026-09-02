#!/usr/bin/perl -w
#
# BrightStart.pm
#
# vi: set ts=2 sw=2 noai expandtab ic showmode showmatch:

=begin comment

perl -MData::Dumper -MFinance::Quote -le '$q = Finance::Quote->new(); print Dumper { $q->fetch("brightstart", @ARGV) };' "Equity Portfolio"

=end comment

=cut

package Finance::Quote::BrightStart;
use strict;
use warnings;

use vars qw /$VERSION/ ;

use LWP::UserAgent;
use HTTP::Request::Common;

# VERSION

my $BRIGHTSTART_URL = 'https://brightstart.com/investment/price-performance/';

our $DISPLAY    = 'BrightStart - Illinois Bright Start 529';
our $FEATURES   = {'ALIASES' => 'file mapping local symbols to portfolio names'};
our @LABELS     = qw/symbol name last nav price currency date isodate method/;
our $METHODHASH = {subroutine => \&brightstart,
                   display    => $DISPLAY,
                   labels     => \@LABELS,
                   features   => $FEATURES};

sub methodinfo {
    return (
        brightstart => $METHODHASH,
    );
}

sub labels {
  my %m = methodinfo();
  return map {$_ => [@{$m{$_}{labels}}] } keys %m;
}

sub methods {
  my %m = methodinfo();
  return map {$_ => $m{$_}{subroutine} } keys %m;
}

# Fold a portfolio name to something comparable. The plan and the calling
# application rarely spell a portfolio the same way, and the trailing word
# "Portfolio" is often dropped.
sub normalise {
  my $s = lc(shift // '');
  $s =~ s/&/ and /g;
  $s =~ s/\bmkt\b/market/g;
  $s =~ s/\bintl\b/international/g;
  $s =~ s/[^a-z0-9]+/ /g;
  $s =~ s/\s+portfolio\s*$//;
  $s =~ s/^\s+|\s+$//g;
  $s =~ s/\s+/ /g;
  return $s;
}

# Optional "symbol = portfolio name" file, for a holding recorded under a
# local code rather than the plan's own wording. Blank lines and # comments
# are ignored.
sub read_aliases {
  my $path = shift;
  my %alias;

  return \%alias unless defined $path and length $path and -r $path;

  open(my $fh, '<', $path) or return \%alias;
  while (my $line = <$fh>) {
    $line =~ s/#.*//;
    next unless $line =~ /\S/;
    my ($from, $to) = $line =~ /^\s*(.+?)\s*=\s*(.+?)\s*$/ or next;
    $alias{normalise($from)} = $to;
  }
  close $fh;

  return \%alias;
}

sub brightstart {
  my ($quoter, @symbols) = @_;

  return unless @symbols;

  my %info;

  $info{$_, 'success'} = 0 for @symbols;

  my $ua = $quoter->user_agent;

  my $response = $ua->request(GET $BRIGHTSTART_URL);
  unless ($response->is_success) {
    $info{$_, 'errormsg'} = 'Error contacting URL' for @symbols;
    return wantarray() ? %info : \%info;
  }

  my $content = $response->decoded_content // '';

  # Every portfolio row names itself in an <a class="fundname"> and carries
  # its unit value in the following cell, labelled "Unit Value as of D/M/YYYY".
  # One request returns all of them, whatever was asked for.
  my (%value, %pubdate, %name);
  while ($content =~ m{
        class="fundname"[^>]*>\s*(?<name>[^<]+?)\s*</a>
        .*?
        Unit\s+Value\s+as\s+of\s+(?<date>\d{1,2}/\d{1,2}/\d{4})\s*</span>
        \s*\$\s*(?<value>[\d,]+\.\d+)
      }gsx) {
    my ($fund, $date, $value) = ($+{name}, $+{date}, $+{value});
    $value =~ s/,//g;
    my $key = normalise($fund);
    $value{$key}   = $value;
    $pubdate{$key} = $date;
    $name{$key}    = $fund;
  }

  unless (%value) {
    $info{$_, 'errormsg'} = 'Parse error' for @symbols;
    return wantarray() ? %info : \%info;
  }

  my $aliases = read_aliases(
      exists $quoter->{module_specific_data}->{brightstart}->{ALIASES}
           ? $quoter->{module_specific_data}->{brightstart}->{ALIASES}
           : $ENV{'BRIGHTSTART_ALIASES'} );

  for my $symbol (@symbols) {
    my $want = normalise($symbol);

    $want = normalise($aliases->{$want}) if exists $aliases->{$want};

    my $key;
    if (exists $value{$want}) {
      $key = $want;
    }
    elsif (exists $value{"$want portfolio"}) {
      $key = "$want portfolio";
    }
    else {
      # Only accept a partial match when exactly one portfolio matches;
      # choosing between several would quietly price the wrong fund.
      my @hits = grep { index($_, $want) >= 0 or index($want, $_) >= 0 }
                 keys %value;
      $key = $hits[0] if scalar(@hits) == 1;
    }

    unless (defined $key) {
      $info{$symbol, 'errormsg'} = 'no match';
      next;
    }

    $info{$symbol, 'symbol'}   = $symbol;
    $info{$symbol, 'name'}     = $name{$key};
    $info{$symbol, 'last'}     = $value{$key};
    $info{$symbol, 'nav'}      = $value{$key};
    $info{$symbol, 'price'}    = $value{$key};
    $info{$symbol, 'currency'} = 'USD';
    $info{$symbol, 'method'}   = 'brightstart';
    $quoter->store_date(\%info, $symbol, {usdate => $pubdate{$key}});
    $info{$symbol, 'success'}  = 1;
  }

  return wantarray() ? %info : \%info;
}

1;

__END__

=head1 NAME

Finance::Quote::BrightStart - Obtain unit values for Illinois Bright Start 529
portfolios

=head1 SYNOPSIS

    use Finance::Quote;

    $q = Finance::Quote->new;

    %info = $q->fetch('brightstart', 'Vanguard Total Stock Market Index 529 Portfolio');

=head1 DESCRIPTION

This module obtains daily unit values for the portfolios of the Illinois
Bright Start Direct-Sold College Savings Program, from the plan's public price
and performance page. No account or API key is needed.

Every portfolio is returned by a single request, so asking for many symbols
costs no more than asking for one.

Bright Start portfolios have no ticker, so the symbol is the portfolio's name.
Matching ignores case and punctuation, tolerates a missing trailing
"Portfolio", and accepts a partial name when exactly one portfolio matches.

=head1 ALIASES

Where a holding is recorded under a local code rather than the plan's own
wording, a file of "symbol = portfolio name" lines can be supplied, either as

    Finance::Quote->new('brightstart' => {ALIASES => '/path/to/file'})

or, for callers that construct Finance::Quote themselves, by setting the
environment variable BRIGHTSTART_ALIASES to the path. Blank lines and text
after a # are ignored.

    DFAINTSMALL = DFA International Small Company 529 Portfolio

=head1 LABELS RETURNED

Information available from Bright Start may include the following labels:

symbol name last nav price currency date isodate method

=head1 SEE ALSO

Illinois Bright Start, https://brightstart.com/

Finance::Quote

=cut
