SELECT entity, last_sync, EXTRACT(EPOCH FROM last_sync):: int AS ts FROM staging.sync_control;
