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

use IPC::Run3;
use POSIX qw(strftime WNOHANG);
use JSON;
use File::Temp qw /tempfile/;
use File::Basename;

# Add directory of script to module search path
use lib dirname (__FILE__);
use Endit qw(%conf readconf printlog getusage);

$Endit::logsuffix = 'tsmretriever.log';

readconf();

my $listfilecounter = 0;

# Try to send warn/die messages to log file
INIT {
        $SIG{__DIE__}=sub {
                printlog("DIE: $_[0]");
        };

        $SIG{__WARN__}=sub {
                print STDERR "$_[0]";
                printlog("WARN: $_[0]");
        };
}

$SIG{INT} = sub { printlog("Got SIGINT, exiting..."); exit; };
$SIG{QUIT} = sub { printlog("Got SIGQUIT, exiting..."); exit; };
$SIG{TERM} = sub { printlog("Got SIGTERM, exiting..."); exit; };

sub checkrequest($) {
	my $req = shift;
	my $req_filename = $conf{'dir'} . '/request/' . $req;
	my $state;

	{
		local $/; # slurp whole file
		# If open failed, probably the request was finished or cancelled
		open my $rf, '<', $req_filename or return undef;
		my $json_text = <$rf>;
		$state = decode_json($json_text);
		close $rf;
	}

	if(!$state || $state->{parent_pid} && getpgrp($state->{parent_pid})<=0)
	{
		printlog "Broken request file $req_filename, removing";
		unlink $req_filename;
		return undef;
	}

	my $in_filename = $conf{'dir'} . '/in/' . $req;
	my $in_filesize=(stat $in_filename)[7];
	if(defined($in_filesize) && defined($state->{file_size}) && $in_filesize == $state->{file_size}) {
		printlog "Not doing $req due to file of correct size already present" if $conf{'verbose'};
		return undef;
	}

	return $state;
}

sub processing_file($$) {
	my ($worker,$file) = @_;
	if($worker) {
		return exists $worker->{files}->{$file};
	} else {
		return 0;
	}
}

my $tapelistmodtime=0;
my $tapelist = {};
my %reqset;
my %lastmount;
my @workers;

printlog("$0: Starting...");

# Warning: Infinite loop. Program may not stop.
while(1) {
#	load/refresh tape list
	if (exists $conf{retriever_hintfile}) {
		my $tapefilename = $conf{retriever_hintfile};
		my $newtapemodtime = (stat $tapefilename)[9];
		if(defined $newtapemodtime) {
			if ($newtapemodtime > $tapelistmodtime) {
				my $newtapelist = Endit::readtapelist($tapefilename);
				if ($newtapelist) {
					my $loadtype = "loaded";
					if(scalar(keys(%{$tapelist}))) {
						$loadtype = "reloaded";
					}
					printlog "Tape hint file $tapefilename ${loadtype}, " . scalar(keys(%{$newtapelist})) . " entries.";

					$tapelist = $newtapelist;
					$tapelistmodtime = $newtapemodtime;
				}
			} 
		} else {
			printlog "Warning: retriever_hintfile set to $conf{retriever_hintfile}, but this file does not seem to exist";
		}
	}

#	check if any dsmc workers are done
	if(@workers) {
		my $timer = 0;
		my $atmax = 0;
		$atmax = 1 if(scalar(@workers) >= $conf{'retriever_maxworkers'});

		while($timer < $conf{sleeptime}) {
			@workers = map {
				my $w = $_;
				my $wres = waitpid($w->{pid}, WNOHANG);
				my $rc = $?;
				if ($wres == $w->{pid}) {
					# Child is done
					$w->{pid} = undef;
					# Intentionally not caring about
					# results. We'll retry and if stuff is
					# really broken, the admins will notice
					# from hanging restore requests anyway.
					unlink $w->{listfile} unless($conf{debug});
				} 
				$w;
			} @workers;
			@workers = grep { $_->{pid} } @workers;

			# Break early if we were waiting for a worker
			# to be freed up.
			if($atmax && scalar(@workers) < $conf{'retriever_maxworkers'})
			{
				last;
			}

			my $st = $conf{sleeptime};
			if($atmax) {
				# Check frequently if waiting for free worker
				$st = 1;
			}
			$timer += $st;
			sleep($st);
		}
	}
	else {
		# sleep to let requester remove requests and pace ourselves
		sleep $conf{sleeptime};
	}

#	read current requests
	{
		%reqset=();
		my $reqdir = "$conf{dir}/request/";
		opendir(my $rd, $reqdir) || die "opendir $reqdir: $!";
		my (@requests) = grep { /^[0-9A-Fa-f]+$/ } readdir($rd); # omit entries with extensions
		closedir($rd);
		if (@requests) {
			foreach my $req (@requests) {
#				It'd be nice to do this here, but takes way too long with a large request list. Instead we only check it when making the requestlist per tape.
#				my $reqinfo = checkrequest($req);
				my $reqfilename=$conf{dir} . '/request/' . $req;
				my $ts =(stat $reqfilename)[9];
				my $reqinfo = {timestamp => $ts } if defined $ts;
				if ($reqinfo) {
					if (!exists $reqinfo->{tape}) {
						if (my $tape = $tapelist->{$req}) {
							$reqinfo->{tape} = $tape;
						} else {
							$reqinfo->{tape} = 'default';
						}
					}
					$reqset{$req} = $reqinfo;
				}
			}
		}
	}

#	if any requests and free worker
	if (%reqset && scalar(@workers) < $conf{'retriever_maxworkers'}) {
#		make list blacklisting pending tapes
		my %usedtapes;
		my $job = {};
		if(@workers) {
			%usedtapes = map { $_->{tape} => 1 } @workers;
		}
		foreach my $name (keys %reqset) {
			my $req = $reqset{$name};
			my $tape;
			if (exists $req->{tape}) {
				$tape = $req->{tape};
			} else {
				warn "tape should have been set for $name, but setting it again!";
				$tape = 'default';
			}
			$job->{$tape}->{$name} = $req;
			if(defined $job->{$tape}->{timestamp}) {
				if($job->{$tape}->{timestamp} > $req->{timestamp}){
					$job->{$tape}->{timestamp} = $req->{timestamp}
				}
			} else {
				$job->{$tape}->{timestamp}=$req->{timestamp};
			}
		}

#		start jobs on tapes not already taken up until retriever_maxworkers
		foreach my $tape (sort { $job->{$a}->{timestamp} <=> $job->{$b}->{timestamp} } keys %{$job}) {
			last if(scalar(@workers) >= $conf{'retriever_maxworkers'});

			printlog "Oldest job on volume $tape: " . strftime("%Y-%m-%d %H:%M:%S",localtime($job->{$tape}->{timestamp})) if($conf{verbose});
			next if exists $usedtapes{$tape};
			next if $tape ne 'default' and defined $lastmount{$tape} && $lastmount{$tape} > time - $conf{retriever_remountdelay};

			my ($lf, $listfile) = tempfile("$tape.XXXXXX", DIR=>"$conf{dir}/requestlists", UNLINK=>0);

			my $lfentries = 0;
			my $lfsize = 0;
			foreach my $name (keys %{$job->{$tape}}) {
				my $reqinfo = checkrequest($name);
				next unless($reqinfo);

				print $lf "$conf{dir}/out/$name\n";
				$lfentries ++;
				if($reqinfo->{file_size}) {
					$lfsize += $reqinfo->{file_size};
				}
			}
			close $lf or die "Closing $listfile failed: $!";

			if(-z $listfile) {
				unlink $listfile;
				next;
			}
			$lastmount{$tape} = time;

			my $lfstats = sprintf("%.2f GiB in %d files", $lfsize/(1024*1024*1024), $lfentries);
			printlog "Running worker on volume $tape ($lfstats)";

#			spawn worker
			my $pid;
			my $j;
			if ($pid = fork) {
				$j=$job->{$tape};
				$j->{pid} = $pid;
				$j->{listfile} = $listfile;
				$j->{tape} = $tape;
				push @workers, $j;
			}
			else {
				undef %usedtapes;
				undef %reqset;
				undef $tapelist;
				undef $job;
				@workers=();

				printlog "Trying to retrieve files from volume $tape using file list $listfile" if($conf{verbose});

				my $indir = $conf{dir} . '/in/';
				my @dsmcopts = split /, /, $conf{'dsmcopts'};
				my @cmd = ('dsmc','retrieve','-replace=no','-followsymbolic=yes',@dsmcopts, "-filelist=$listfile",$indir);
				printlog "Executing: " . join(" ", @cmd) if($conf{debug});

				my ($in,$out,$err);
				$in="A\n";
				if((run3 \@cmd, \$in, \$out, \$err) && $? == 0) {
					# files migrated from tape without issue
					printlog "Successfully retrieved files from volume $tape";
					# sleep to let requester remove requests
					sleep 3;
					exit 0;
				} else {
					my $msg = "dsmc retrieve failure volume $tape file list $listfile: ";
					if ($? == -1) {
						$msg .= "failed to execute: $!";
					}
					elsif ($? & 127) {
						$msg .= sprintf "child died with signal %d, %s coredump", ($? & 127),  ($? & 128) ? 'with' : 'without';
					}
					else {
						$msg .= sprintf "child exited with value %d\n", $? >> 8;
					}
					printlog "$msg";
					printlog "STDERR: $err";
					printlog "STDOUT: $out";

					# sleep to pace ourselves if these are
					# persistent reoccurring failures
					sleep $conf{sleeptime};

					# Any number of requests broke, try
					# again later
                			exit 1;
				}
			}
		}
	}
}
