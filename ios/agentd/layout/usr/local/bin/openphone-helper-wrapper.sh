#!/var/jb/bin/sh
# launchd starts the setuid protected-data helper through this /bin/sh wrapper so
# the helper inherits sh's unsandboxed session context. Launching the daemon
# binary directly from launchd applies the platform sandbox and the helper gets
# "authorization denied" on SMS/CallHistory/Calendar SQLite. See IOS_PLAN.md T2-7.
export OPENPHONE_AGENTD_STORE=/var/mobile/Library/OpenPhone/protected-data-helper
export OPENPHONE_AGENTD_ROLE=protected_data_helper
export OPENPHONE_AGENTD_DISABLE_TASK_REPAIR=1
export OPENPHONE_AGENTD_DISABLE_VOLUME_TRIGGER=1
export OPENPHONE_AGENTD_DISABLE_APP_UI_INTAKE=1
export OPENPHONE_AGENTD_DISABLE_BACKGROUND_SCHEDULER=1
export HOME=/var/mobile
exec /var/jb/usr/local/bin/openphone-protected-data-helper
