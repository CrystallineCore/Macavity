--
-- macavity: input validation.  Every case here must fail, and none of them
-- may leave a fault armed.
--
-- unknown fault point
SELECT macavity_arm('wal_insert', 'error');
SELECT macavity_arm('', 'error');
SELECT macavity_arm('EXECUTOR_START', 'error');

-- unknown action
SELECT macavity_arm('executor_start', 'panic');
SELECT macavity_arm('executor_start', 'ERROR');

-- occurrence must be positive
SELECT macavity_arm('executor_start', 'error', 0);
SELECT macavity_arm('executor_start', 'error', -1);

-- nulls are reported, not silently ignored
SELECT macavity_arm(NULL, 'error');
SELECT macavity_arm('executor_start', NULL);
SELECT macavity_arm('executor_start', 'error', NULL);

-- 'error' cannot be injected into abort processing
SELECT macavity_arm('before_abort', 'error');

-- nothing above may have armed anything
SELECT * FROM macavity_status();

-- the point/action lists are still intact after all that
SELECT count(*) AS points FROM macavity_points();
