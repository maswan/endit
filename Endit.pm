#   ENDIT - Efficient Northern Dcache Interface to TSM
#   Copyright (C) 2006-2017 Mattias Wadenstein <maswan@hpc2n.umu.se>
#
#   This program is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see <http://www.gnu.org/licenses/>.

package Endit;
use strict;
use warnings;
use IPC::Run3;
use POSIX qw(strftime);
use File::Temp qw /tempfile/;

our (@ISA, @EXPORT_OK);
BEGIN {
	require Exporter;
	@ISA = qw(Exporter);
	@EXPORT_OK = qw(%conf readconf printlog getusage);
}


our $logsuffix;
our %conf;

sub printlog($) {
	my $msg = shift;
	my $now = strftime '%Y-%m-%d %H:%M:%S', localtime;

	my $lf;
	if($conf{'logdir'}) {
		my $logfilename = $conf{'logdir'} . '/' . $logsuffix;
		open $lf, '>>', $logfilename or warn "Failed to open $logfilename: $!";
	}

	chomp($msg);
	my $str = "$now [$$] $msg\n";

	if($lf && $lf->opened) {
		print $lf $str;
		if(!close($lf)) {
			print $str;
		}
	} else {
		print $str;
	}
}

my %confold2new = (
	timeout => 'archiver_timeout',
	minusage => 'archiver_threshold1_usage',
	maxretrievers => 'retriever_maxworkers',
	tapefile => 'retriever_hintfile',
	remounttime => 'retriever_remountdelay',
);

my %confobsolete = (
	hsminstance => 1,
	remotedirs => 1,
	pollinginterval => 1,
	maxusage => 1,
);

my %confitems = (
	dir => {
		example => '/grid/pool',
		desc => 'Base directory',
	},
	logdir => {
		example => '/var/log/dcache',
		desc => 'Log directory',
	},
	dsmcopts => {
		example => '-asnode=EXAMPLENODE, -errorlogname=/var/log/dcache/dsmerror.log',
		desc => 'Base options to dsmc, ", "-delimited list',
	},
	sleeptime => {
		default => 60,
		desc => 'Sleep for this many seconds between each cycle',
	},
	archiver_timeout => {
		default => 21600,
		example => 21600,
		desc => "Push to tape anyway after these many seconds.\nThis should be significantly shorter than the store timeout, commonly 1 day.",
	},
	archiver_timeout_dsmcopts => {
		desc => 'Extra dsmcopts for archiver_timeout',
	},
	archiver_threshold1_usage => {
		default => 500,
		example => 500,
		desc => "Require this usage before migrating to tape, in gigabytes.\nTune this to be 20-30 minutes or more of tape activity.",
	},
	archiver_threshold1_dsmcopts => {
		desc => 'Extra dsmcopts for archiver_threshold1',
	},
	archiver_threshold2_usage => {
		example => 2000,
		desc => "When exceeding this usage, in gigabytes, apply additonal dsmcopts.\nCommonly used to trigger usage of multiple tape sessions if one\nsession can't keep up. Recommended setting is somewhere between\ntwice the archiver_threshold1_usage and 20% of the total pool size.",
	},
	archiver_threshold2_dsmcopts => {
		example => "-resourceutilization=5",
		desc => "Resourceutilization 5 -> 2 producers (ie. write 2 tapes concurrently).\nNote: Node must have MAXNUMMP increased from default 1.",
	},
	archiver_threshold3_usage => {
		desc => "Also archiver_threshold3 ... archiver_threshold9 available if needed.",
	},
	archiver_threshold3_dsmcopts => {},
	archiver_threshold4_usage => {},
	archiver_threshold4_dsmcopts => {},
	archiver_threshold5_usage => {},
	archiver_threshold5_dsmcopts => {},
	archiver_threshold6_usage => {},
	archiver_threshold6_dsmcopts => {},
	archiver_threshold7_usage => {},
	archiver_threshold7_dsmcopts => {},
	archiver_threshold8_usage => {},
	archiver_threshold8_dsmcopts => {},
	archiver_threshold9_usage => {},
	archiver_threshold9_dsmcopts => {},
	retriever_maxworkers => {
		default => 1,
		example => 3,
		desc => "Maximum number of concurrent dsmc retrievers.\nNote: Node must have MAXNUMMP increased from default 1.",
	},
	retriever_remountdelay => {
		default => 600,
		desc => "When in concurrent mode, don't remount tapes more often than this, seconds",
	},
	retriever_hintfile => {
		example => "/var/spool/endit/tapehints/EXAMPLENODE.txt",
		desc => "Tape hints file for concurrent dsmc retrievers. Generate using\ntsm_getvolumecontent.pl for the -asnode user you configured in dsmcopts",
	},

	verbose => {
		default => 0,
		desc => 'Enable verbose logging (1/true to enable)',
	},
	debug => {
		default => 0,
		desc => 'Enable debug mode/logging (1/true to enable)',
	},
);

# Sort function that orders component specific configuration directives
# after common ones.
sub confdirsort {
	return 1 if($a=~/_/ && $b!~/_/);
	return -1 if($b=~/_/ && $a!~/_/);

	return $a cmp $b;
}

sub writesampleconf() {

	my($fh, $fn) = tempfile("endit.conf.sample.XXXXXX", UNLINK=>0, TMPDIR=>1);

	print $fh "# Endit sample configuration file.\n";
	print $fh "# Generated on " . scalar(localtime(time())) . "\n";
	print $fh "\n";
	print $fh "# Note, comments have to start with # in the first character of the line\n";
	print $fh "# Otherwise, simple \"key: value\" pairs\n";

	foreach my $k (sort confdirsort keys %confitems) {
		next unless($confitems{$k}{desc});

		print $fh "\n";
		my @desc = split(/\n/, $confitems{$k}{desc});
		print $fh "# ", join("\n# ", @desc), "\n";
		if(defined($confitems{$k}{default})) {
			print $fh "# (default $confitems{$k}{default})\n";
		}

		if(defined($confitems{$k}{example})) {
			print $fh "$k: $confitems{$k}{example}\n";
		}
		elsif(defined($confitems{$k}{default})) {
			print $fh "# $k: $confitems{$k}{default}\n";
		}
		else {
			print $fh "# $k:\n";
		}
	}

	close($fh) || warn "Closing $fn: $!";

	printlog "Sample configuration file written to $fn";
}

sub readconf() {
	my $conffile = '/opt/endit/endit.conf';

	# Apply defaults
	foreach my $k (keys %confitems) {
		next unless(defined($confitems{$k}{default}));

		$conf{$k} = $confitems{$k}{default};
	}

	if($ENV{ENDIT_CONFIG}) {
		$conffile = $ENV{ENDIT_CONFIG};
	}

	printlog "Using configuration file $conffile";

	my $cf;
	if(!open $cf, '<', $conffile) {
		warn "Can't open $conffile: $!";
		writesampleconf();
		die "No configuration, exiting...";
	}
	while(<$cf>) {
		next if $_ =~ /^#/;
		chomp;
		next unless($_);
		next if(/^\s+$/);

		my($key,$val) = split /:\s+/;
		if(!defined($key) || !defined($val) || $key =~ /^\s/ || $key =~ /\s$/) {
			die "Aborting on garbage config line: '$_'";
			next;
		}

		if($confold2new{$key}) {
			warn "Config directive $key deprecated, please use $confold2new{$key} instead";
			$key = $confold2new{$key};
		}

		if($confobsolete{$key}) {
			warn "Config directive $key OBSOLETE, skipping";
			next;
		}

		if(!$confitems{$key}) {
			warn "Config directive $key UNKNOWN, skipping";
			next;
		}

		$conf{$key} = $val;
	}

	# Verify that required parameters are defined
	foreach my $param (qw{dir logdir dsmcopts}) {
		if(!defined($conf{$param})) {
			die "$conffile: $param is a required parameter, exiting";
		}
	}

	# Verify that dir is present and writable
	if(! -d "$conf{dir}") {
		die "Required directory $conf{dir} missing, exiting";
	}
	my($fh, $fn) = tempfile(".endit.XXXXXX", DIR=>"$conf{dir}"); # croak():s on error

	close($fh);
	unlink($fn);

	# Verify that required subdirs are present and writable
	foreach my $subdir (qw{in out request requestlists trash}) {
		if(! -d "$conf{dir}/$subdir") {
			die "Required directory $conf{dir}/$subdir missing, exiting";
		}
		($fh, $fn) = tempfile(".endit.XXXXXX", DIR=>"$conf{dir}/$subdir"); # croak():s on error

		close($fh);
		unlink($fn);
	}
}

# Return filessystem usage (gigabytes)
sub getusage($@) {
	my $dir = shift;
	my $size = 0;

	printlog "Getting size of files in $dir: ". join(" ", @_) if($conf{debug});

	while(my $file = shift) {
		next unless(-e "$dir/$file");

		$size += (stat _)[7];
	}

	printlog "Total size: $size bytes" if($conf{debug});

	return $size/(1024*1024*1024); # GiB
}

sub readtapelist($) {
	my $tapefile = shift;
	printlog "reading tape list $tapefile" if $conf{verbose};
	my $out = {};
	open my $tf, '<', $tapefile or return undef;
	while (<$tf>) {
		chomp;
		my ($id,$tape) = split /\s+/;
		next unless defined $id && defined $tape;
		$tape=~tr/a-zA-Z0-9.-/_/cs;
		$out->{$id} = $tape;
	}
	close($tf);
	return $out;
}

1;
