#include <sys/file.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "minieap_common.h"
#include "logging.h"
#include "config.h"
#include "misc.h"
#include "pid_lock.h"

#define PID_STRING_BUFFER_SIZE 12
#define PID_FILE_NONE "none"
#define ONLINE_SUFFIX ".online"

static int pid_lock_fd = 0; // 0 = uninitialized, -1 = disabled

RESULT pid_lock_init(const char* pidfile) {
    if (pidfile == NULL) {
        return FAILURE;
    }

    if (strcmp(pidfile, PID_FILE_NONE) == 0) {
        PR_WARN("PID 检查已禁用，请确保一个接口上只有一个认证进程")
        pid_lock_fd = -1;
        return SUCCESS;
    }

    int open_flags = O_RDWR;
    if (getenv("MINIEAP_REQUIRE_EXISTING_FILES") == NULL) {
        open_flags |= O_CREAT;
    }
#ifdef O_NOFOLLOW
    open_flags |= O_NOFOLLOW;
#endif
    pid_lock_fd = open(pidfile, open_flags, 0644);
    if (pid_lock_fd < 0) {
        PR_ERRNO("无法打开 PID 文件");
        return FAILURE;
    }
    return SUCCESS;
}

// Return SUCCESS: We handled the incident and are ready to proceed (i.e. only when user asked)
// Return FAILURE: We could not handle, or we do not want to proceed
static RESULT pid_lock_handle_multiple_instance() {
    char readbuf[PID_STRING_BUFFER_SIZE]; // 12 is big enough to hold PID number
    if (lseek(pid_lock_fd, 0, SEEK_SET) < 0) {
        PR_ERRNO("无法读取其他 MiniEAP 进程的 PID");
        return FAILURE;
    }

    ssize_t read_length = read(pid_lock_fd, readbuf, sizeof(readbuf) - 1);
    if (read_length <= 0) {
        PR_ERR("已有另一个 MiniEAP 进程正在运行但 PID 未知，请手动结束其他 MiniEAP 进程");
        return FAILURE;
    }
    readbuf[read_length] = '\0';
    for (ssize_t index = 0; index < read_length; ++index) {
        if (readbuf[index] < '0' || readbuf[index] > '9') {
            PR_ERR("已有另一个 MiniEAP 进程的 PID 文件无效，请手动结束其他 MiniEAP 进程");
            return FAILURE;
        }
    }

    int pid = atoi(readbuf);
    if (pid <= 0) {
        PR_ERR("已有另一个 MiniEAP 进程的 PID 无效，请手动结束其他 MiniEAP 进程");
        return FAILURE;
    }
    switch (get_program_config()->kill_type) {
        case KILL_NONE:
            PR_ERR("已有另一个 MiniEAP 进程正在运行，PID 为 %d", pid);
            return FAILURE;
        case KILL_ONLY:
            PR_ERR("已有另一个 MiniEAP 进程正在运行，PID 为 %d，即将发送终止信号并退出……", pid);
            kill(pid, SIGTERM);
            return FAILURE;
        case KILL_AND_START:
            PR_WARN("已有另一个 MiniEAP 进程正在运行，PID 为 %d，将在发送终止信号后继续……", pid);
            kill(pid, SIGTERM);
            return SUCCESS;
        default:
            PR_ERR("-k 参数未知");
            return FAILURE;
    }
}

RESULT pid_lock_save_pid() {
    if (pid_lock_fd == 0) {
        PR_WARN("PID 文件尚未初始化");
        return FAILURE;
    } else if (pid_lock_fd < 0) {
        // User disabled pid lock
        return SUCCESS;
    }

    char writebuf[PID_STRING_BUFFER_SIZE];

    my_itoa(getpid(), writebuf, 10);
    size_t write_length = strnlen(writebuf, PID_STRING_BUFFER_SIZE);
    if (ftruncate(pid_lock_fd, 0) < 0 || lseek(pid_lock_fd, 0, SEEK_SET) < 0) {
        PR_ERRNO("无法清理 PID 文件");
        return FAILURE;
    }

    ssize_t written = write(pid_lock_fd, writebuf, write_length);
    if (written != (ssize_t)write_length) {
        if (written < 0) {
            PR_ERRNO("无法将 PID 保存到 PID 文件");
        } else {
            PR_ERR("PID 文件写入不完整");
        }
        return FAILURE;
    }

    return SUCCESS;
}

RESULT pid_lock_lock() {
    if (pid_lock_fd == 0) {
        PR_WARN("PID 文件尚未初始化");
        return FAILURE;
    } else if (pid_lock_fd < 0) {
        // User disabled pid lock
        return SUCCESS;
    }

    int lock_result = flock(pid_lock_fd, LOCK_EX | LOCK_NB);
    if (lock_result < 0) {
        if (errno == EWOULDBLOCK) {
            if (IS_FAIL(pid_lock_handle_multiple_instance())) {
                close(pid_lock_fd);
                pid_lock_fd = 0;
                return FAILURE;
            } // Continue if handled
        } else {
            PR_ERRNO("无法对 PID 文件加锁");
            return FAILURE;
        }
    }

    return SUCCESS;
}

RESULT pid_lock_destroy() {
    pid_lock_clear_online();

    if (pid_lock_fd <= 0) {
        return SUCCESS;
    }

    if (ftruncate(pid_lock_fd, 0) < 0 || lseek(pid_lock_fd, 0, SEEK_SET) < 0) {
        PR_WARN("无法清理 PID 文件");
    }
    close(pid_lock_fd); // Unlocks the file simultaneously
    pid_lock_fd = 0;
    return SUCCESS;
}

// Returns FAILURE only on unexpected I/O error; missing pidfile config is not an error here.
static int build_online_path(char* buf, size_t buf_size) {
    const char* pidfile = get_program_config() ? get_program_config()->pidfile : NULL;
    if (pidfile == NULL || strcmp(pidfile, PID_FILE_NONE) == 0) {
        return FALSE;
    }
    int written = snprintf(buf, buf_size, "%s%s", pidfile, ONLINE_SUFFIX);
    return written > 0 && (size_t)written < buf_size;
}

RESULT pid_lock_mark_online() {
    char online_path[600];
    if (!build_online_path(online_path, sizeof(online_path))) {
        return SUCCESS; // Nothing to mark, not an error
    }
    int open_flags = O_WRONLY | O_CREAT | O_TRUNC;
#ifdef O_NOFOLLOW
    open_flags |= O_NOFOLLOW;
#endif
    int fd = open(online_path, open_flags, 0644);
    if (fd < 0) {
        PR_ERRNO("无法写入在线状态标记文件");
        return FAILURE;
    }
    close(fd);
    return SUCCESS;
}

void pid_lock_clear_online() {
    char online_path[600];
    if (!build_online_path(online_path, sizeof(online_path))) {
        return;
    }
    unlink(online_path);
}
