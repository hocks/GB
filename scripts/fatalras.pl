#!/usr/bin/perl 

# Check BGL event log for fatal RAS errors in last 24 hours

use POSIX qw(ENOENT strftime);

# establish required DB2 env variables
$ENV{DB2INSTANCE} = "bgdb2cli";
$ENV{LD_LIBRARY_PATH} = "/u/bgdb2cli/sqllib/lib";
$ENV{PATH} = "$ENV{PATH}:/u/bgdb2cli/sqllib/bin";

# connect to the database
$pw = get_db2_pw();
run_and_hide("db2 connect to bgdb0 user bglsysdb using $pw");

# Set lookback interval
$now = time();
#$yesterday = ($now - 44100);	# Lookback is 12 hours 15 minutes
#$yesterday = ($now - 86400);	# Lookback is 24 hours
## $yesterday = ($now - (5*86400));
$yesterday = ($now - (1460*86400)); # Lookback prev 4 years
$START_TIME = strftime("%Y-%m-%d-%H.%M.%S.00", localtime($yesterday));
$END_TIME = strftime("%Y-%m-%d-%H.%M.%S.00", localtime($now));

# these are the errors we're interested in
$L3="%L3 major internal error%";
$DDR="%uncorrectable error detected in external DDR%";
$TORUS="%uncorrectable torus error%";

$Q="db2 \"select event_time, location, entry_data from bgleventlog where event_time between '$START_TIME' and '$END_TIME' and severity = 'FATAL'\"";

print "$Q\n" if $debug == 1;

##$Q="db2 \"select event_time, location, entry_data from bgleventlog where event_time between '$START_TIME' and '$END_TIME' and (entry_data like '$L3' or entry_data like '$DDR' or entry_data like '$TORUS') order by event_time\"";
## $Q="db2 \"select event_time, location, entry_data from bgleventlog where event_time between '$START_TIME' and '$END_TIME' order by event_time\"";

$major_error = 0;
open (QUERY, "$Q |");
while (<QUERY>) {
	chomp;
	next if /EVENT_TIME/;	# skip db2 cruft
	next if /------/;	# skip db2 cruft
	next if /selected/;	# skip db2 cruft
	next if (/^$/);		# skip blank lines
	($e,$l,$d) = split (/\s+/, $_, 3);
	printf ("%-14s %-19s %-80s\n",format_time($e),$l,substr($d,0,120));
# Filter out minor errors
	next if /invalid or missing program image/;
	next if /program image too big/;
	next if /rts internal error/;
	next if /tree sender channel/;
        next if /idoproxy communication failure: socket closed/;
	next if /Collective network link receiver fifos are not empty/;
	next if /Kill\s+job \d+ timed out\. Block freed\./;
	$major_error = 1;
}
close (QUERY);

run_and_hide("db2 terminate");
exit($major_error);

sub get_db2_pw {

	my $field, $value;
	my $dbp = "/bgl/BlueLight/ppcfloor/bglsys/bin/db.properties";

	open (DBP, "< $dbp") or die "Cannot open $dbp: $!";
	while (<DBP>) {
		chomp;
		next unless /database_password/;
		($field,$value) = split(/=/,$_,2);
	}
	return $value;
}

sub run_and_hide {
# if we redirect stdout to /dev/null when using system(), perl will run 
# the command through the shell and our database connection will be lost.
# Instead we'll use a pipe and just discard stdout.

	my ($cmd) = @_;

	open (PIPE, "$cmd | ");
	while (<PIPE>) {
		next;
	}
	close PIPE;
}

sub format_time {
#  reformat event_time
#  input format: yyyy-mm-dd-hh:mm:ss.xxxx
#  output format: mm-dd-hh:mm:ss

	my ($slm) = @_;
	my ($ts1,$ts2,$ts3,$foo) = split (/\./,$slm, 4);
	#$ts1 =~ s/^[0-9]+\-//g;		# strip year off of date stamp
	return "$ts1:$ts2:$ts3";
}


