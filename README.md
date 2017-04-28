Distributed Cron
==============
The name says it all. This is something I did for work, and they were kind enough to let me put it on github. The CRUD feature for the web pages is something we have at work, by hooking an existing CRUD site into this. I plan to add some simple add/delete pages at some point in the future.


Description
===========
A Perl program that mostly does what cron does, but across multiple computers.

Install
=======
* Run distributed_cron.sql to install the database and table.
* Configure distributed_cron.yml
* Figure the best way to execute the distributed_cron.pl
** We are lazy, and just put the following into our crontab. There exists some code that makes sure multiple copies don't run.

`* * * * * cronjob perl /path/to/code/distributed_cron.pl`

** Alternatively you could replace the first line with the second in distributed_cron.pl and launch it on system startup.

`while ( $job_count->[0] or $manager->running_procs ) { `

`while ( 1 ) { `

* Update the MySQL settings for the index.cgi. Either point it at the config, or give it it's own settings.
* Next Make the web directory, well, web accessible. A simple symlink works.
* Last step would be to start adding entries to the job table.

Assumptions
===========
* The centralized authority is the DBMS. It's timezone is the timezone used. It is the single point of failure.
* A cron can be ran from any of the machines. They all have the necessary, permissions, and access to run a job.
* The time between the update call, and select call  for retrieving set jobs is less than a second, update this in the config if that isn't true for your network. 
** IF you have PostgreSQL you can alter the SQL to combine these two, with UPDATE ... RETURNING.
* The child process won't crash.

TODO
====
* Add CRUD for the web page.
* Execute Now, for a job.

Recipes
========
* Problem: I want a cron that only runs during 11pm - 3am.
* Solution: Split it into two crons, one with only a start anchor, and one with only a stop anchor. For the start anchor use 11pm. For the stop anchor use 3am.


