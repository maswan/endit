package Endit;
use strict;
use warnings;
use IPC::Run3;
use POSIX qw(strftime);

our (@ISA, @EXPORT_OK);
BEGIN {
	require Exporter;
	@ISA = qw(Exporter);
	@EXPORT_OK = qw(%conf readconf printlog getusage);
}


our $logsuffix;
our %conf;

sub readconf($) {
	my $conffile = shift;
	my $key;
	my $val;
#	warn "opening conffile $conffile";
	open CF, '<'.$conffile or die "Can't open conffile: $!";
	while(<CF>) {
		next if $_ =~ /^#/;
		chomp;
		($key,$val) = split /: /;
		next unless defined $val;
		$conf{$key} = $val;
	}
}

sub printlog($) {
	my $msg = shift;
	my $now = strftime '%Y-%m-%d %H:%M:%S ', localtime;
	open LF, '>>' . $conf{'logdir'} . '/' . $logsuffix or warn "Failed to open " . $conf{'logdir'} . '/' . $logsuffix . ": $!";
	print LF $now . $msg;
	close LF;
}

# Return filessystem usage (gigabytes)
sub getusage($) {
	my $dir = shift;
	my ($out,$err,$size);
	my @cmd = ('du','-ks',$dir);
	if((run3 \@cmd, \undef, \$out, \$err) && $? ==0) {
		($size, undef) = split ' ',$out;
	} else {
		# failed to run du, probably just a disappearing file.
		printlog "failed to run du: $err\n";
		# Return > maxusage to try again in a minute or two
		return $conf{'maxusge'} + 1024;
	}
	return $size/1024/1024;
}

1;
