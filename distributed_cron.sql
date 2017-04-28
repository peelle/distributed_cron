CREATE DATABASE IF NOT EXISTS distributed_cron CHARACTER SET utf8 COLLATE utf8_unicode_ci;

use distributed_cron;

DROP TABLE IF EXISTS job;
 
CREATE TABLE IF NOT EXISTS job ( 
	id 		INT UNSIGNED 	NOT NULL PRIMARY KEY AUTO_INCREMENT,

	description 	VARCHAR(100) 	NOT NULL 	DEFAULT 'Yet another cron',
	command		VARCHAR(2000) 	NOT NULL 	DEFAULT 'echo "I forgot to put in a command."',

	active		TINYINT(1)	NOT NULL 	DEFAULT 1
	start_anchor	TIME,
	stop_anchor	TIME,
	frequency	INT UNSIGNED 	NOT NULL 	DEFAULT 60,
	max_run_time	INT UNSIGNED 	NOT NULL 	DEFAULT 1,

	last_start	DATETIME,
	last_end	DATETIME,
	last_status	VARCHAR(32) 			DEFAULT 'Never ran.',
	last_worker	VARCHAR(64) 			DEFAULT 'Never ran.',

	INDEX (active),
	INDEX (start_anchor),
	INDEX (stop_anchor),
	INDEX (frequency) USING BTREE,
	INDEX (last_start) USING BTREE,
	INDEX (last_end) USING BTREE
);


DROP TRIGGER IF EXISTS job_checks;
delimiter //
CREATE TRIGGER job_checks BEFORE INSERT ON job  
FOR EACH ROW
BEGIN
	IF NEW.frequency < 1 THEN  /* Make sure we don't set a crazy weird frequency */
		SET NEW.frequency = 1;
	END IF;
	
	IF NEW.max_run_time < 1 OR NEW.max_run_time >= NEW.frequency THEN /* Make sure the max run time is less than our run frequency */
		SET NEW.max_run_time = NEW.frequency / 2;
	END IF;


END;//
delimiter ;
