#!/usr/bin/env perl

use Modern::Perl;
use FindBin qw( $Bin );
use YAML::Tiny;
use Logger::Simple;
use Fcntl qw(:flock);
use Sys::Hostname;
use Sys::CpuAffinity;
use DBI;
use Try::Tiny;
use Parallel::ForkManager;
use Data::Dumper;

##################
# SETUP & CHECKS #
##################
# Load config
my $config = YAML::Tiny->read( $Bin . '/distributed_cron.yml' );

# Give our parent a unique name
my $parent_name = hostname . '-' . $$; 

# Set up logging
mkdir $config->[0]->{log}->{location} if ( not -e $config->[0]->{log}->{location} and not -d $config->[0]->{log}->{location} );
my $log = Logger::Simple->new( LOG => $config->[0]->{log}->{location} . '/' . hostname . '.log' );
$log->write("$$: Parent Process Starting.");

# Check if there is already a local parent running and quit if so.
# Using a simple, clean, solution from: http://www.perlmonks.org/?node_id=590619
( $log->write("$$: Already running. Exiting.") && exit) unless flock(DATA, LOCK_EX|LOCK_NB);

# Setup process job vars
my $max_tasks = $config->[0]->{max_tasks} eq 'cpu_full'
				? Sys::CpuAffinity::getNumCpus()
				: $config->[0]->{max_tasks} eq 'cpu_half'
					? ( Sys::CpuAffinity::getNumCpus() / 2 )
					: $config->[0]->{max_tasks} eq 'cpu_quarter'
						? ( Sys::CpuAffinity::getNumCpus() / 4 )
						: $config->[0]->{max_tasks};

( $log->write("Invalid process count $max_tasks.") && exit ) if $max_tasks < 1;

# DB SETUP
my $dbh = DBI->connect($config->[0]->{db}->{connect_string}, $config->[0]->{db}->{username}, $config->[0]->{db}->{password}, { mysql_auto_reconnect => 1, PrintError => 1 } ) 
        or ( $log->write("Could not connecto MySQL") and die("Could not connect to the database."));

# Clear old or locked tasks. This is needed if we start up after a crash, or kill.
if ( $config->[0]->{clear_old_on_start} eq 'yes' ) {
	$dbh->do("UPDATE job SET last_end = NULL, last_status = 'Cleared' WHERE last_worker like '". hostname ."-%' AND last_end < last_start ");
} elsif ( $config->[0]->{clear_old_on_start} ne 'no' ) {
	warn('Bad value for clear_old_on_start only "yes" or "no" supported. Ignoring.');
}

my $check_jobs_where_clause = 	' active = 1 AND 
				( start_anchor IS NULL OR start_anchor < CURRENT_TIME() ) AND 		# It is inside our start anchor
				( stop_anchor IS NULL OR stop_anchor > CURRENT_TIME() ) AND    		# It is inside our stop anchor
				( last_start IS NULL OR 				       		# It has not been ran
					( last_start <= DATE_SUB(NOW(), INTERVAL frequency MINUTE ) AND # Our wait frequency has elapsed
					( last_end IS NULL OR last_start <= last_end )	                # Our last run has stopped.
				))';

my $check_jobs_sth = $dbh->prepare("SELECT count(*) FROM job WHERE $check_jobs_where_clause");
my $update_jobs_sth = $dbh->prepare('UPDATE job 	
					SET 
						last_start = NOW(),					# Mark Job as started
						last_worker = ?						# Set owner for this run
					WHERE 
					' . $check_jobs_where_clause . '				# Same parameters as check
					ORDER BY RAND(UNIX_TIMESTAMP())					# Grab a random sampling
					LIMIT ?');							# Limit by max_tasks
                                        #would be better if we updated a job when it actually started instead of when it was queued.
                                        #although in theory, it the slots are available then it should start almost immediately.

my $get_jobs_sth = $dbh->prepare('SELECT * FROM job 	
					WHERE 
						active = 1 AND 
						( start_anchor IS NULL OR start_anchor < CURRENT_TIME() ) AND 	
						( stop_anchor IS NULL OR stop_anchor > CURRENT_TIME() ) AND 
                                                ( last_start > last_end OR last_end IS NULL ) AND      # With the time delay we cannot start a child the same second we ended the same job.
						last_worker = ?
					LIMIT ?');

my $report_job = $dbh->prepare('UPDATE job 
                                        SET
                                                last_end = NOW(),
                                                last_status = ?
                                        WHERE 
                                                active = 1 AND 
                                                id = ? AND
                                                last_worker = ?
                                        LIMIT 1');

$check_jobs_sth->execute;
my $job_count = $check_jobs_sth->fetch;

( $log->write("$$: No available jobs. Exiting") and exit ) unless $job_count->[0]; # No reason to go any further if there aren't any jobs to process.

my $manager = Parallel::ForkManager->new( $max_tasks );
my %running_jobs; # hashes of job_id => process_id
$manager->run_on_start(
        sub { my ($pid,$ident)=@_;
                print "**" .  $ident->[0] . "started, pid: $pid\n";
                $running_jobs{ $ident->[0] } = $pid;
        }
);
$manager->run_on_finish(
        sub { 
                my ($pid, $exit_code, $ident) = @_;
		my $status = ( 0 == $exit_code ) ? 'Sucess' : "ERROR: $exit_code";
                my $return_value = undef; # part of the code to ensure a final result is written>
                $log->write("*" . $ident->[0] ."  just got out of the pool with PID $pid and exit code: $exit_code");
                $running_jobs{ $ident->[0] } = undef;
                do { 
                        $return_value = $report_job->execute($status, $ident->[0], $parent_name);
                        $log->write("$parent_name: Failed to write ident status for $ident->[0].  DBI ERROR: ".$dbh->errstr) unless defined $return_value;
                        sleep 1 unless defined $return_value;
                } while ( not defined $return_value );
        }
);

########
# Main #
########

while ( $job_count->[0] or $manager->running_procs ) { # Will only run as long as SQL has available jobs or there is currently a job running.

	my $job_data; # Clear job every time.
	if ( $manager->is_parent ) { # Grab our list of tasks to execute.

                sleep 2; # A reasonable wait until checking for new jobs.
		$check_jobs_sth->execute;
		$job_count = $check_jobs_sth->fetch;
		$log->write("$$: Available Jobs: " . $job_count->[0] . "\tRunning Processes: " . scalar( $manager->running_procs ) . '/' . $max_tasks );
                $log->write("process assocciation count: " . scalar(grep { defined($running_jobs{$_})  } keys(%running_jobs) ) );

		if ( $job_count->[0] and scalar ( $manager->running_procs ) < $max_tasks ) {
                        $update_jobs_sth->execute($parent_name, ( $max_tasks - scalar ( $manager->running_procs ) ) );
                        $get_jobs_sth->execute($parent_name, ( $max_tasks - scalar ( $manager->running_procs ) ) );
                        $job_data = $get_jobs_sth->fetchall_arrayref;
                        $log->write("$$: New set of jobs grabbed: " . scalar(@$job_data));
		} else {
			sleep 1;
		}
	}

	foreach my $job ( @$job_data ) {
                next if $running_jobs{ $job->[0] };  # process already running
		my $pid = $manager->start( $job ) and next; # Start child.

		# CHILD CODE BEGINS
                $dbh->{InactiveDestroy} = 1; # DBI code to do forking right.
		my $exit_status = 0;
		open(my $job_log, '>>', ($config->[0]->{log}->{location} . '/' . $job->[0] . '.log') ) or $log->write("$parent_name: Couldn't open $job->[0].log");

		# Pipe open the command and get it's pid.
		my $command_pid = open( my $fh, "exec 2>&1; $job->[2] |") or ( say $job_log "[" . localtime . "] couldn't execute: $!");


		# Set an alarm, to kill long running processes.
		$SIG{ALRM} = sub { 
                        $manager->finish(-1); # This should end the child code early.
		};
		alarm ($job->[7] * 60); # This is the timeout value in seconds.

		while(<$fh>) { # captured output from the command.
			say $job_log "$parent_name: [" . localtime . "] $_";
		}
		close $fh; # waits for the process to finish..

		$exit_status = $? ? $? : 0; # $? is where close puts the status of the command executed.

		alarm 0; # Reminder: The parent process doesn't execute this code.
		close $job_log;

		$manager->finish($exit_status);
                # CHILD CODE ENDS.
	}
	$manager->reap_finished_children;
}

$log->write("$$: Ran all available jobs. Waiting on any last children...");
$manager->wait_all_children;
$log->write("$$: Finshed. Exiting.");


__DATA__
This exists so flock() code above works.
DO NOT REMOVE THIS DATA SECTION.
