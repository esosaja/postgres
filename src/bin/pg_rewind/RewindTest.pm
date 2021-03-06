package RewindTest;

# Test driver for pg_rewind. Each test consists of a cycle where a new cluster
# is first created with initdb, and a streaming replication standby is set up
# to follow the master. Then the master is shut down and the standby is
# promoted, and finally pg_rewind is used to rewind the old master, using the
# standby as the source.
#
# To run a test, the test script (in t/ subdirectory) calls the functions
# in this module. These functions should be called in this sequence:
#
# 1. init_rewind_test - sets up log file etc.
#
# 2. setup_cluster - creates a PostgreSQL cluster that runs as the master
#
# 3. create_standby - runs pg_basebackup to initialize a standby server, and
#    sets it up to follow the master.
#
# 4. promote_standby - runs "pg_ctl promote" to promote the standby server.
# The old master keeps running.
#
# 5. run_pg_rewind - stops the old master (if it's still running) and runs
# pg_rewind to synchronize it with the now-promoted standby server.
#
# 6. clean_rewind_test - stops both servers used in the test, if they're
# still running.
#
# The test script can use the helper functions master_psql and standby_psql
# to run psql against the master and standby servers, respectively. The
# test script can also use the $connstr_master and $connstr_standby global
# variables, which contain libpq connection strings for connecting to the
# master and standby servers. The data directories are also available
# in paths $test_master_datadir and $test_standby_datadir

use strict;
use warnings;

use TestLib;
use Test::More;

use File::Copy;
use File::Path qw(remove_tree);
use IPC::Run qw(run start);

use Exporter 'import';
our @EXPORT = qw(
  $connstr_master
  $connstr_standby
  $test_master_datadir
  $test_standby_datadir

  append_to_file
  master_psql
  standby_psql
  check_query

  init_rewind_test
  setup_cluster
  create_standby
  promote_standby
  run_pg_rewind
  clean_rewind_test
);

# A temporary directory created with 'tempdir' is deleted automatically at
# the end of the tests. You can change it to a constant if you need to keep it
# for debugging purposes,
my $testroot = tempdir;

our $test_master_datadir="$testroot/data_master";
our $test_standby_datadir="$testroot/data_standby";

mkdir $testroot;

# Log files are created here
mkdir "regress_log";

# Define non-conflicting ports for both nodes.
my $port_master=$ENV{PGPORT};
my $port_standby=$port_master + 1;

my $log_path;
my $tempdir_short;

my $connstr_master="port=$port_master";
my $connstr_standby="port=$port_standby";

$ENV{PGDATABASE} = "postgres";

sub master_psql
{
	my $cmd = shift;

	system_or_bail("psql -q --no-psqlrc -d $connstr_master -c \"$cmd\"");
}

sub standby_psql
{
	my $cmd = shift;

	system_or_bail("psql -q --no-psqlrc -d $connstr_standby -c \"$cmd\"");
}

# Run a query against the master, and check that the output matches what's
# expected
sub check_query
{
	my ($query, $expected_stdout, $test_name) = @_;
	my ($stdout, $stderr);

	# we want just the output, no formatting
	my $result = run ['psql', '-q', '-A', '-t', '--no-psqlrc',
					  '-d', $connstr_master,
					  '-c' , $query],
					 '>', \$stdout, '2>', \$stderr;
	# We don't use ok() for the exit code and stderr, because we want this
	# check to be just a single test.
	if (!$result) {
		fail ("$test_name: psql exit code");
	} elsif ($stderr ne '') {
		diag $stderr;
		fail ("$test_name: psql no stderr");
	} else {
		is ($stdout, $expected_stdout, "$test_name: query result matches");
	}
}

# Run a query once a second, until it returns 't' (i.e. SQL boolean true).
sub poll_query_until
{
	my ($query, $connstr) = @_;

	my $max_attempts = 30;
	my $attempts = 0;
	my ($stdout, $stderr);

	while ($attempts < $max_attempts)
	{
		my $cmd = ['psql', '-At', '-c', "$query", '-d', "$connstr" ];
		my $result = run $cmd, '>', \$stdout, '2>', \$stderr;

		chomp($stdout);
		if ($stdout eq "t")
		{
			return 1;
		}

		# Wait a second before retrying.
		sleep 1;
		$attempts++;
	}

	# The query result didn't change in 30 seconds. Give up. Print the stderr
	# from the last attempt, hopefully that's useful for debugging.
	diag $stderr;
	return 0;
}

sub append_to_file
{
	my($filename, $str) = @_;

	open my $fh, ">>", $filename or die "could not open file $filename";
	print $fh $str;
	close $fh;
}

sub init_rewind_test
{
	my $testname = shift;
	my $test_mode = shift;

	$log_path="regress_log/pg_rewind_log_${testname}_${test_mode}";

	remove_tree $log_path;
}

sub setup_cluster
{
	$tempdir_short = tempdir_short;

	# Initialize master, data checksums are mandatory
	remove_tree($test_master_datadir);
	standard_initdb($test_master_datadir);

	# Custom parameters for master's postgresql.conf
	append_to_file("$test_master_datadir/postgresql.conf", qq(
wal_level = hot_standby
max_wal_senders = 2
wal_keep_segments = 20
max_wal_size = 200MB
shared_buffers = 1MB
wal_log_hints = on
hot_standby = on
autovacuum = off
max_connections = 10
));

	# Accept replication connections on master
	append_to_file("$test_master_datadir/pg_hba.conf", qq(
local replication all trust
));

	system_or_bail("pg_ctl -w -D $test_master_datadir -o \"-k $tempdir_short --listen-addresses='' -p $port_master\" start >>$log_path 2>&1");

	#### Now run the test-specific parts to initialize the master before setting
	# up standby
	$ENV{PGHOST}         = $tempdir_short;
}

sub create_standby
{
	# Set up standby with necessary parameter
	remove_tree $test_standby_datadir;

	# Base backup is taken with xlog files included
	system_or_bail("pg_basebackup -D $test_standby_datadir -p $port_master -x >>$log_path 2>&1");
	append_to_file("$test_standby_datadir/recovery.conf", qq(
primary_conninfo='$connstr_master application_name=rewind_standby'
standby_mode=on
recovery_target_timeline='latest'
));

	# Start standby
	system_or_bail("pg_ctl -w -D $test_standby_datadir -o \"-k $tempdir_short --listen-addresses='' -p $port_standby\" start >>$log_path 2>&1");

	# Wait until the standby has caught up with the primary, by polling
	# pg_stat_replication.
	my $caughtup_query = "SELECT pg_current_xlog_location() = replay_location FROM pg_stat_replication WHERE application_name = 'rewind_standby';";
	poll_query_until($caughtup_query, $connstr_master)
		or die "Timed out while waiting for standby to catch up";
}

sub promote_standby
{
	#### Now run the test-specific parts to run after standby has been started
	# up standby

	# Now promote slave and insert some new data on master, this will put
	# the master out-of-sync with the standby. Wait until the standby is
	# out of recovery mode, and is ready to accept read-write connections.
	system_or_bail("pg_ctl -w -D $test_standby_datadir promote >>$log_path 2>&1");
	poll_query_until("SELECT NOT pg_is_in_recovery()", $connstr_standby)
		or die "Timed out while waiting for promotion of standby";
}

sub run_pg_rewind
{
	my $test_mode = shift;

	# Stop the master and be ready to perform the rewind
	system_or_bail("pg_ctl -w -D $test_master_datadir stop -m fast >>$log_path 2>&1");

	# At this point, the rewind processing is ready to run.
	# We now have a very simple scenario with a few diverged WAL record.
	# The real testing begins really now with a bifurcation of the possible
	# scenarios that pg_rewind supports.

	# Keep a temporary postgresql.conf for master node or it would be
	# overwritten during the rewind.
	copy("$test_master_datadir/postgresql.conf", "$testroot/master-postgresql.conf.tmp");
	# Now run pg_rewind
	if ($test_mode eq "local")
	{
		# Do rewind using a local pgdata as source
		# Stop the master and be ready to perform the rewind
		system_or_bail("pg_ctl -w -D $test_standby_datadir stop -m fast >>$log_path 2>&1");
		my $result =
			run(['pg_rewind',
				 "--debug",
				 "--source-pgdata=$test_standby_datadir",
				 "--target-pgdata=$test_master_datadir"],
				'>>', $log_path, '2>&1');
		ok ($result, 'pg_rewind local');
	}
	elsif ($test_mode eq "remote")
	{
		# Do rewind using a remote connection as source
		my $result =
			run(['pg_rewind',
				 "--source-server", "port=$port_standby dbname=postgres",
				 "--target-pgdata=$test_master_datadir"],
				'>>', $log_path, '2>&1');
		ok ($result, 'pg_rewind remote');
	} else {
		# Cannot come here normally
		die("Incorrect test mode specified");
	}

	# Now move back postgresql.conf with old settings
	move("$testroot/master-postgresql.conf.tmp", "$test_master_datadir/postgresql.conf");

	# Plug-in rewound node to the now-promoted standby node
	append_to_file("$test_master_datadir/recovery.conf", qq(
primary_conninfo='port=$port_standby'
standby_mode=on
recovery_target_timeline='latest'
));

	# Restart the master to check that rewind went correctly
	system_or_bail("pg_ctl -w -D $test_master_datadir -o \"-k $tempdir_short --listen-addresses='' -p $port_master\" start >>$log_path 2>&1");

	#### Now run the test-specific parts to check the result
}

# Clean up after the test. Stop both servers, if they're still running.
sub clean_rewind_test
{
	if ($test_master_datadir)
	{
		system "pg_ctl -D $test_master_datadir -s -m immediate stop 2> /dev/null";
	}
	if ($test_standby_datadir)
	{
		system "pg_ctl -D $test_standby_datadir -s -m immediate stop 2> /dev/null";
	}
}

# Stop the test servers, just in case they're still running.
END
{
	my $save_rc = $?;
	clean_rewind_test();
	$? = $save_rc;
}
