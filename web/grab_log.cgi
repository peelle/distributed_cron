#!/usr/bin/perl

use Modern::Perl;
use URI::Escape;
use Sys::Hostname;

say "Content-type: text/HTML\n\n<pre>";

my $hostname = $ENV{QUERY_STRING}||hostname; # A quick hack to dump an individual log completely.
my $output;
if($hostname ne hostname) {
	$output =  `cat /tmp/distributed_cron/$hostname.log`;
} else {
	$output =  `tail /tmp/distributed_cron/$hostname.log`;
}

print $output;

