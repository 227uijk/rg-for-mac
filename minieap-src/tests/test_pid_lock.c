#include <assert.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>

#include "config.h"
#include "logging.h"
#include "misc.h"
#include "pid_lock.h"

static PROG_CONFIG test_config;

PROG_CONFIG *get_program_config(void) {
    return &test_config;
}

void print_log(const char *level, const char *func, const char *format, ...) {
    (void)level;
    (void)func;
    (void)format;
}

void print_log_raw(const char *format, ...) {
    (void)format;
}

char *my_itoa(int value, char *buffer, uint32_t radix) {
    assert(radix == 10);
    snprintf(buffer, 32, "%d", value);
    return buffer;
}

static void read_file(const char *path, char *buffer, size_t capacity) {
    int fd = open(path, O_RDONLY);
    assert(fd >= 0);
    ssize_t count = read(fd, buffer, capacity - 1);
    assert(count >= 0);
    buffer[count] = '\0';
    close(fd);
}

int main(void) {
    char path[] = "/tmp/ruijie-pid-lock-test-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    assert(write(fd, "12345678901", 11) == 11);
    close(fd);

    test_config.pidfile = path;
    assert(pid_lock_init(path) == SUCCESS);
    assert(pid_lock_lock() == SUCCESS);
    assert(pid_lock_save_pid() == SUCCESS);

    char actual[32];
    char expected[32];
    read_file(path, actual, sizeof(actual));
    snprintf(expected, sizeof(expected), "%d", (int)getpid());
    assert(strcmp(actual, expected) == 0);

    assert(pid_lock_destroy() == SUCCESS);
    assert(access(path, F_OK) == 0);
    read_file(path, actual, sizeof(actual));
    assert(actual[0] == '\0');
    unlink(path);

    char missing_path[] = "/tmp/ruijie-pid-lock-missing-XXXXXX";
    int missing_fd = mkstemp(missing_path);
    assert(missing_fd >= 0);
    close(missing_fd);
    unlink(missing_path);
    setenv("MINIEAP_REQUIRE_EXISTING_FILES", "1", 1);
    test_config.pidfile = missing_path;
    assert(pid_lock_init(missing_path) == FAILURE);
    assert(access(missing_path, F_OK) != 0);
    unsetenv("MINIEAP_REQUIRE_EXISTING_FILES");

    char target_path[] = "/tmp/ruijie-pid-lock-target-XXXXXX";
    int target_fd = mkstemp(target_path);
    assert(target_fd >= 0);
    close(target_fd);
    char link_path[] = "/tmp/ruijie-pid-lock-link-XXXXXX";
    int link_fd = mkstemp(link_path);
    assert(link_fd >= 0);
    close(link_fd);
    unlink(link_path);
    assert(symlink(target_path, link_path) == 0);
    test_config.pidfile = link_path;
#ifdef O_NOFOLLOW
    assert(pid_lock_init(link_path) == FAILURE);
#else
    assert(pid_lock_init(link_path) == SUCCESS);
    assert(pid_lock_destroy() == SUCCESS);
#endif
    unlink(link_path);
    unlink(target_path);

    char req_pid[] = "/tmp/ruijie-pid-lock-req-XXXXXX";
    int req_fd = mkstemp(req_pid);
    assert(req_fd >= 0);
    close(req_fd);
    test_config.pidfile = req_pid;
    char req_path[600];
    snprintf(req_path, sizeof(req_path), "%s%s", req_pid, PID_LOCK_REQUEST_STOP);
    assert(pid_lock_take_request(PID_LOCK_REQUEST_STOP) == FALSE);
    int stop_fd = open(req_path, O_WRONLY | O_CREAT, 0644);
    assert(stop_fd >= 0);
    close(stop_fd);
    assert(pid_lock_take_request(PID_LOCK_REQUEST_REAUTH) == FALSE);
    assert(pid_lock_take_request(PID_LOCK_REQUEST_STOP) == TRUE);
    assert(access(req_path, F_OK) != 0);
    assert(pid_lock_take_request(PID_LOCK_REQUEST_STOP) == FALSE);
    assert(symlink(req_pid, req_path) == 0);
    assert(pid_lock_take_request(PID_LOCK_REQUEST_STOP) == FALSE); // Not a regular file
    unlink(req_path);
    unlink(req_pid);
    return 0;
}
