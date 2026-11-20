#include "if_impl.h"
#include "packet_builder.h"
#include "logging.h"
#include "net_util.h"
#include "packet_plugin_rjv3_priv.h"
#include "misc.h"
#include "packet_util.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <signal.h>
#include <pcap.h>

/*
 * 心跳实现说明（macOS 修复版）
 *
 * 原实现把心跳挂在 SIGALRM 处理器里，处理器内直接调用 pcap_inject()
 * 往主线程 pcap_loop() 正在使用的那个 handle 注入帧。libpcap 不可重入，
 * 在 macOS 上这一步会死锁：认证成功 +1 秒的第一次心跳就把进程卡死在
 * 信号处理器内部，之后所有闹钟（包括控制通道轮询）全部停摆，
 * 心跳一帧也发不出去 —— 服务端在会话超时（实测 250 秒）后清理会话。
 *
 * 修复方式：心跳改用独立线程 + 自己独占的 pcap handle，
 * 与主线程的抓包 handle 完全隔离，不再有任何可重入风险。
 */

#define PRIV ((rjv3_priv*)(this->priv))

#define KA_FRAME_MAX 128
#define KA_FIRST_DELAY 2 /* 认证成功后第一次心跳的延迟（秒） */

static uint32_t g_echokey;
static uint32_t g_echono;
static uint8_t g_dest_mac[6];
// The main thread rewrites these on re-auth (rjv3_process_result_prop) while
// the heartbeat thread builds frames from them.
static pthread_mutex_t g_ka_params_lock = PTHREAD_MUTEX_INITIALIZER;

/* 独立心跳线程状态 */
static pthread_t g_ka_thread;
static volatile int g_ka_running = 0;
static volatile int g_ka_stop = 0;
static int g_ka_interval = 60;
static char g_ka_ifname[IFNAMSIZ] = {0};
static uint8_t g_ka_src_mac[6];

void rjv3_set_keepalive_echokey(uint32_t key) {
    pthread_mutex_lock(&g_ka_params_lock);
    g_echokey = key;
    pthread_mutex_unlock(&g_ka_params_lock);
}

void rjv3_set_keepalive_echono(uint32_t no) {
    pthread_mutex_lock(&g_ka_params_lock);
    g_echono = no;
    pthread_mutex_unlock(&g_ka_params_lock);
}

void rjv3_set_keepalive_dest_mac(uint8_t* mac) {
    pthread_mutex_lock(&g_ka_params_lock);
    memmove(g_dest_mac, mac, 6);
    pthread_mutex_unlock(&g_ka_params_lock);
}

void rjv3_keepalive_reset() {
    /* 只置停止标志，由线程自己退出；此函数可能在信号处理器上下文中被调用，
     * 因此绝对不能在这里 pthread_join。 */
    g_ka_stop = 1;
    g_echokey = 0;
    g_echono = 0;
}

/* 组装一帧完整的锐捷私有心跳（以太网头 + EAPOL 头 + 27 字节载荷） */
static int build_keepalive_frame(uint8_t* out) {
    static const uint8_t _tpl[27] = {
        0xFF, 0xFF, 0x37, 0x77, 0x7F, 0x9F, 0xFF, 0xFF, 0xD9, 0x13, 0xFF, 0xFF, 0x37, 0x77,
        0x7F, 0x9F, 0xFF, 0xFF, 0xF7, 0x2B, 0xFF, 0xFF, 0x37, 0x77, 0x7F, 0x3F, 0xFF
    };
    uint8_t _body[27];
    uint8_t* _p = out;
    uint8_t _dest[6];
    uint32_t _num1, _num2;
    pthread_mutex_lock(&g_ka_params_lock);
    memmove(_dest, g_dest_mac, 6);
    _num1 = g_echokey + g_echono;
    _num2 = g_echono++;
    pthread_mutex_unlock(&g_ka_params_lock);
    memmove(_body, _tpl, sizeof(_body));
    _body[6]  = (uint8_t)~bit_reverse((_num1 >> 24) & 0xff);
    _body[7]  = (uint8_t)~bit_reverse((_num1 >> 16) & 0xff);
    _body[8]  = (uint8_t)~bit_reverse((_num1 >> 8) & 0xff);
    _body[9]  = (uint8_t)~bit_reverse(_num1 & 0xff);
    _body[16] = (uint8_t)~bit_reverse((_num2 >> 24) & 0xff);
    _body[17] = (uint8_t)~bit_reverse((_num2 >> 16) & 0xff);
    _body[18] = (uint8_t)~bit_reverse((_num2 >> 8) & 0xff);
    _body[19] = (uint8_t)~bit_reverse(_num2 & 0xff);

    memmove(_p, _dest, 6);        _p += 6;   /* 目的 MAC：服务端 */
    memmove(_p, g_ka_src_mac, 6); _p += 6;   /* 源 MAC：本机网卡 */
    *_p++ = 0x88; *_p++ = 0x8e;              /* EtherType：EAPOL */
    *_p++ = 0x01;                            /* EAPOL version = 1 */
    *_p++ = (uint8_t)EAPOL_RJ_PROPRIETARY_KEEPALIVE; /* 0xbf */
    *_p++ = 0x00; *_p++ = 30;                /* 保持与官方客户端一致的声明长度 */
    memmove(_p, _body, sizeof(_body)); _p += sizeof(_body);

    return (int)(_p - out);
}

static void* ka_thread_main(void* unused) {
    // Threads inherit the creator's signal mask; when we are created inside a
    // packet-receive callback SIGALRM is unblocked and the alarm handler would
    // run auth callbacks on this thread, racing the main thread's packet work.
    sigset_t _alarms;
    sigemptyset(&_alarms);
    sigaddset(&_alarms, SIGALRM);
    pthread_sigmask(SIG_BLOCK, &_alarms, NULL);

    char _errbuf[PCAP_ERRBUF_SIZE] = {0};
    pcap_t* _handle = pcap_open_live(g_ka_ifname, 64, 0, 200, _errbuf);

    if (_handle == NULL) {
        PR_ERR("心跳线程无法打开网卡 %s：%s", g_ka_ifname, _errbuf);
        g_ka_running = 0;
        return NULL;
    }

    int _waited = 0;
    int _first = 1;

    while (!g_ka_stop) {
        sleep(1);
        if (g_ka_stop) {
            break;
        }
        _waited++;
        if (_waited < (_first ? KA_FIRST_DELAY : g_ka_interval)) {
            continue;
        }
        _waited = 0;
        _first = 0;

        uint8_t _frame[KA_FRAME_MAX];
        int _len = build_keepalive_frame(_frame);
        if (pcap_inject(_handle, _frame, (size_t)_len) < 0) {
            PR_ERR("心跳包发送失败：%s", pcap_geterr(_handle));
        }
    }

    pcap_close(_handle);
    g_ka_running = 0;
    return NULL;
}

void rjv3_keepalive_start(struct _packet_plugin* this) {
    IF_IMPL* _if = NULL;

    /* 已在运行且没被要求停止：什么都不做（避免出现第二条心跳链） */
    if (g_ka_running && !g_ka_stop) {
        return;
    }
    /* 旧的线程正在退出：给它一点时间，避免两条链重叠 */
    if (g_ka_running && g_ka_stop) {
        int _wait = 0;
        while (g_ka_running && _wait < 4) {
            sleep(1);
            _wait++;
        }
        if (g_ka_running) {
            PR_ERR("旧的心跳线程尚未退出，跳过本次启动");
            return;
        }
    }

    _if = get_if_impl();
    if (_if == NULL) {
        PR_ERR("心跳启动失败：网络界面未初始化");
        return;
    }
    if (IS_FAIL(_if->get_ifname(_if, g_ka_ifname, sizeof(g_ka_ifname)))) {
        PR_ERR("心跳启动失败：无法获取网卡名");
        return;
    }
    if (IS_FAIL(obtain_iface_mac(g_ka_ifname, g_ka_src_mac))) {
        PR_ERR("心跳启动失败：无法获取源 MAC");
        return;
    }

    g_ka_interval = (PRIV->heartbeat_interval > 0) ? PRIV->heartbeat_interval : 60;
    g_ka_stop = 0;

    pthread_attr_t _attr;
    pthread_attr_init(&_attr);
    pthread_attr_setdetachstate(&_attr, PTHREAD_CREATE_DETACHED);

    // Mark running before create: a thread that fails pcap_open_live clears
    // this itself, and must not be overwritten back to 1 afterwards.
    g_ka_running = 1;
    if (pthread_create(&g_ka_thread, &_attr, ka_thread_main, NULL) != 0) {
        g_ka_running = 0;
        pthread_attr_destroy(&_attr);
        PR_ERR("心跳启动失败：无法创建线程");
        return;
    }
    pthread_attr_destroy(&_attr);

    PR_INFO("心跳线程已启动（网卡 %s，间隔 %d 秒，独立 pcap handle）", g_ka_ifname, g_ka_interval);
}
