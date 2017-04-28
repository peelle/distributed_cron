#!/usr/bin/perl

use Modern::Perl;
use Template;
use DBI;
use CGI::Simple;

my $q = CGI::Simple->new();

say "Content-type: text/html\n\n";


my $template = Template->new() || die "$Template::ERROR\n";
my $template_vars;

my $dbh = DBI->connect('dbi:mysql:database=distributed_cron;host=mysql_host', 'username', 'password') || die "Couldn't get a DB Connection\n";

my $running_count = $dbh->selectall_arrayref('SELECT count(*) FROM job WHERE last_start > last_end');
my $overdue_count = $dbh->selectall_arrayref('SELECT count(*) FROM job WHERE last_start < DATE_SUB(NOW(), INTERVAL frequency MINUTE)');
my $waiting_count = $dbh->selectall_arrayref('SELECT count(*) FROM job WHERE last_start > DATE_SUB(NOW(), INTERVAL frequency MINUTE)');
my $disabled_count = $dbh->selectall_arrayref('SELECT count(*) FROM job WHERE active = 0');
my $error_count = $dbh->selectall_arrayref('SELECT count(*) FROM job WHERE last_status like "%ERROR%"');

my $job_list = $dbh->selectall_arrayref('SELECT *, 
        IF(last_start > last_end, "Running", IF(active = 0, "Disabled", 
        IF(last_start < DATE_SUB(NOW(), INTERVAL frequency MINUTE), 
        "Overdue", "Last Run" ))) as current_status1, 
        IF(last_start > last_end, TIMESTAMPDIFF(MINUTE, last_start, NOW()), IF(active = 0, -1, 
        IF(last_start < DATE_SUB(NOW(), INTERVAL frequency MINUTE), 
        TIMESTAMPDIFF(MINUTE, last_start, DATE_SUB(NOW(), INTERVAL frequency MINUTE)), 
        TIMESTAMPDIFF(MINUTE, DATE_SUB(last_start, INTERVAL frequency MINUTE), last_end )
        ))) as current_status2
        FROM job ORDER BY current_status1 DESC, last_start DESC, last_end DESC');

$template_vars = {
        job_list => $job_list,
        running_count => $running_count->[0]->[0],
        overdue_count => $overdue_count->[0]->[0],
        waiting_count => $waiting_count->[0]->[0],
        disabled_count => $disabled_count->[0]->[0],
        error_count => $error_count->[0]->[0],
        search_string => ($q->param('search_string') // ''),
};

$template->process('index.tt', $template_vars) || die $template->error(), "\n";
