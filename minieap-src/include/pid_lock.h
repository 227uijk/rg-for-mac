#ifndef MINIEAP_PID_LOCK_H
#define MINIEAP_PID_LOCK_H

RESULT pid_lock_init(const char* pidfile);
RESULT pid_lock_lock();
RESULT pid_lock_save_pid();
RESULT pid_lock_destroy();

/*
 * Mark/clear a companion "<pidfile>.online" marker file.
 * Written only once EAP_SUCCESS is actually reached, cleared as soon as
 * we are no longer sure we are online (offline detected, or process exiting).
 * Lets outside supervisors (e.g. the menu bar app) tell "process alive"
 * apart from "actually authenticated", instead of just checking the PID.
 */
RESULT pid_lock_mark_online();
void pid_lock_clear_online();

#endif