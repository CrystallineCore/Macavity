--
-- macavity: input validation.  Every case here must fail, and none of them
-- may leave an event in the registry.
--
-- unknown fault point
SELECT macavity_arm('wal_insert', 'error');
SELECT macavity_arm('', 'error');
SELECT macavity_arm('EXECUTOR_START', 'error');
SELECT macavity_arm_error('wal_insert');
SELECT macavity_arm_delay('');

-- unknown action
SELECT macavity_arm('executor_start', 'panic');
SELECT macavity_arm('executor_start', 'ERROR');

-- occurrence must be positive
SELECT macavity_arm('executor_start', 'error', 0);
SELECT macavity_arm('executor_start', 'error', -1);
SELECT macavity_arm_delay('executor_start', 0);
SELECT macavity_arm_crash('executor_start', -1);

-- nulls are reported, not silently ignored
SELECT macavity_arm(NULL, 'error');
SELECT macavity_arm('executor_start', NULL);
SELECT macavity_arm('executor_start', 'error', NULL);
SELECT macavity_arm_error(NULL);
SELECT macavity_arm_delay('executor_start', NULL);
SELECT macavity_arm(NULL::integer);

-- 'error' cannot be injected into abort processing, by either form
SELECT macavity_arm('before_abort', 'error');
SELECT macavity_arm_error('before_abort');

-- reinstating needs an event that exists
SELECT macavity_arm(1);
SELECT macavity_arm(0);
SELECT macavity_arm(-1);

-- nothing above may have created anything
SELECT * FROM macavity_status();

-- disarming an ID that does not exist is not an error, just a no-op
SELECT macavity_disarm(1);
SELECT macavity_disarm(-1);

-- a failed arm does not consume an event ID: the first real event is 1
SELECT macavity_arm('executor_start', 'error', 400);
SELECT macavity_reset();

-- the point/action lists are still intact after all that
SELECT count(*) AS points FROM macavity_points();
