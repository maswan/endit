#!/usr/bin/perl

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


use warnings;
use strict;
use English;


use File::Path;
use File::Copy;
use File::Basename;
use Digest::MD5 qw(md5_hex);
use POSIX qw(strftime);
use JSON;


use lib '/opt/endit/';
use Endit qw(%conf readconf printlog getusage);

$Endit::logsuffix = 'endit.log';

readconf(); 
die "No basedir!\n" unless $conf{'dir'};
warn "No logdir!\n" unless $conf{'logdir'};
warn "No logsuffix!\n" unless $Endit::logsuffix;

printlog 'endit.pl starting: ' . join (' ', @ARGV) . "\n";

####################
# Arguments
my $command = shift; # get|put|remove
my $pnfsid;
my $filename;
if($command eq 'get' or $command eq 'put') {
	$pnfsid = shift;
	$filename = shift;
	if(!defined($filename)) {
        	printlog "Argument error, too few arguments for $command.\n";
        	exit 35;
	}
}

my %options;

foreach my $opt (@ARGV) {
	$options{$1} = $2 if $opt =~ /^-(\w+)=(\S+)$/
		or printlog "Warning: Bad argument $opt\n";
}

if($command eq 'get' and !defined($options{'si'})) {
	printlog "Argument error: lacking si for get.\n";
	exit 35;
}

if($command eq 'put' and !defined($options{'si'})) {
	printlog "Argument error: lacking si for put.\n";
	exit 35;
}

if($command eq 'remove' and !defined($options{'uri'})) {
	printlog "Argument error: lacking uri for remove.\n";
	exit 35;
}

if($command eq 'remove') {
# uri: print "osm://hpc2n.umu.se/?store=$store&group=$group&bfid=$pnfsid\n";
	my $pnfsid;
	$pnfsid = $1 if $options{'uri'}  =~ /.*bfid=(\w+)/;
	if(!defined($pnfsid)) {
		printlog "couldn't parse $options{'uri'}\n";
		exit 32;
	}
	if(-f $conf{'dir'} . '/out/' . $pnfsid) {
		unlink $conf{'dir'} . '/out/' . $pnfsid;
	}
	if(defined $conf{'remotedirs'}) {
		# Check if it is in any of the remote caches
		my @remotedirs = split / /, $conf{'remotedirs'};
		foreach my $remote (@remotedirs) {
			unlink $remote . '/' . $pnfsid;
		}
	}
	if(open FH,'>',$conf{'dir'} . '/trash/' . $pnfsid) {
		print FH "$options{'uri'}\n";
		close FH;
		# all is good..
	} else {
		printlog "touch $conf{'dir'}/trash/$pnfsid failed: $!\n";
		exit 32;
	}
}

if($command eq 'put') {
	my $dir = $conf{'dir'};
	my $usage = getusage($dir . '/out/');
	$conf{'pollinginterval'} = 300 unless $conf{'pollinginterval'};
	while ($usage>$conf{'maxusage'}) {
		printlog "$usage used, sleeping until less than $conf{'maxusage'}\n" if $conf{'verbose'};
		sleep $conf{'pollinginterval'};
		$usage = getusage($dir . '/out/');
	}
	
	my $size;
	my $store;
	my $group;
	my $si = $options{'si'};
	my @keyval = split /;/,$si;
	foreach my $k (@keyval) {
		if($k =~ /^size=(\d+)/) {
			$size=$1;
		}
		if($k =~ /^store=(.+)/) {
			$store=$1;
		}
		if($k =~ /^group=(.+)/) {
			$group=$1;
		}
	}

	if(link($filename,$dir . '/out/' . $pnfsid)) {
	} else {
		# If the file already exists in out/ it must have been migrated
		# but dCache forgot about it, proceed to "success".
		unless($!{EEXIST}) {
			printlog "Failed to link $filename to $dir/out/$pnfsid: $!\n";
			exit 30;
		}
	}
	{
		# new pnfs-free interface
		my $hsminstance;
		if(defined($conf{'hsminstance'})) {
			$hsminstance=$conf{'hsminstance'};
		} else {
			$hsminstance=`hostname -d`;
			chomp $hsminstance;
		}
		printlog "osm://$hsminstance/?store=$store&group=$group&bfid=$pnfsid\n" if $conf{'verbose'};
		print "osm://$hsminstance/?store=$store&group=$group&bfid=$pnfsid\n";
	}
}

if($command eq 'get') {
	my $si = $options{'si'};

	my $dirname = dirname($filename);
	my $dir = $conf{'dir'};

	# Now we need size out of $si
	my $size;
	my @keyval = split /;/,$si;
	foreach my $k (@keyval) {
		if($k =~ /size=(\d+)/) {
			$size=$1;
		}
	}
	
	if(-f $filename) {
		my @stat = stat $filename;
		if (defined $stat[7] && $stat[7] == $size) {
			exit 0; 
		} elsif ($stat[7] == 0) {
			printlog "Working around 0-sized file bug.\n";
		} else {
			printlog "Asked to restore a file that already exists with a different size!\n";
			printlog "The file was $filename ($pnfsid), exiting...\n";
			exit 37;
		}
	}
	
	if(! -d $dirname) {
         	eval { mkpath($dirname) };
         	if ($@) {
			printlog "Couldn't create $dirname: $@\n";
			exit 32;
         	}
	}
	
	if(link($dir . '/out/' . $pnfsid, $filename)) {
		# We got lucky, file not removed from migration dir yet
		exit 0;
	} else {
		# printlog "Debug: link failed: $!\n";
		# We are less lucky, have to get it from tape...
	}

	my $insize;
	if(defined $conf{'remotedirs'}) {
		# Check if it is in any of the remote caches
		my @remotedirs = split / /, $conf{'remotedirs'};
		foreach my $remote (@remotedirs) {
			if(-f $remote . '/' . $pnfsid) {
				if(copy($remote . '/' . $pnfsid, $dir . '/in/' . $pnfsid)) {
					$insize = (stat $dir . '/in/' . $pnfsid)[7];
					if(defined $insize && $insize == $size) {
						if(rename $dir . '/in/' . $pnfsid, $filename) {
							exit 0;
						} else {
							printlog "mv $pnfsid $filename failed: $!\n";
							exit 33;
						}
					} else {
						printlog "Copy of $remote/$pnfsid returned 1, but had wrong size!\n";
						unlink $filename;
					}
				} else {
					printlog "Remote cache steal failed for $remote/$pnfsid: $!\n";
					unlink $filename;
				}
			}
		}
	}
	
	my $req_filename = "$dir/request/$pnfsid";
	if(open my $fh, '>', "$req_filename.stage") {
		my $state = { parent_pid => $PID, basetime => $BASETIME, file_size => $size };
		print $fh encode_json($state);
		close $fh;
		rename("$req_filename.stage", $req_filename); # atomic move
		# all is good..
	} else {
		printlog "generating $dir/request/$pnfsid failed: $!\n";
		exit 32;
	}
	
	do {
		sleep 5;
		my $errfile=$dir . '/request/' . $pnfsid . '.err';
		if(-f $errfile) {
			sleep 1;
			open my $in, '<', $errfile || die "Unable to open $errfile: $!";
			my @err = <$in>;
			close($in);
			unlink $errfile;
			unlink $dir . '/request/' . $pnfsid;
			unlink $dir . '/in/' . $pnfsid;
			if($err[0] > 0) {
				exit $err[0]; # Error code in first line
			} else {
				exit 32;
			}
		}
		$insize = (stat $dir . '/in/' . $pnfsid)[7];
	} until (defined $insize && $insize == $size);

	if(unlink $dir . '/request/' . $pnfsid) {
		# all is well..
	} else {
		printlog "Warning, unlink $dir/request/$pnfsid failed: $!\n";
	}

	if(rename $dir . '/in/' . $pnfsid, $filename) {
		exit 0;
	} else {
		printlog "mv $pnfsid $filename failed: $!\n";
		exit 33;
	}
}

exit 0;
