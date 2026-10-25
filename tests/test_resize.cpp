#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>
#include <sys/socket.h>
#include <unistd.h>
// Inspect state transitions while using the real module callbacks and IPC.
#define private public
#include "osxup/osxup.h"
#undef private

extern "C" void* mod_init();
extern "C" int mod_exit(void*);
static int completed;
static int resize_done(mod*) { ++completed; return 0; }

static std::vector<int> packet(int fd) {
    int bytes;
    assert(read(fd, &bytes, sizeof(bytes)) == sizeof(bytes));
    assert(bytes > 0 && bytes < 2048 && bytes % 4 == 0);
    std::vector<int> result(bytes / 4);
    char* dst = reinterpret_cast<char*>(result.data());
    for (int used = 0; used < bytes;) {
        int count = static_cast<int>(read(fd, dst + used, bytes - used));
        assert(count > 0);
        used += count;
    }
    return result;
}

int main() {
    int sockets[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    mod* m = static_cast<mod*>(mod_init());
    assert(m != nullptr);
    for (int requested : {-1, 0, 1, 16, 100, 1000}) {
        intptr_t reads[16] = {}, writes[16] = {}; int nr = 0, nw = 0, timeout = requested;
        assert(m->mod_get_wait_objs(m, reads, &nr, writes, &nw, &timeout) == 0);
        assert(timeout == ((requested < 0 || requested > 100) ? 100 : requested));
    }
    puts("PASS: module preserves immediate/short core deadlines and bounds idle polling");
    auto* cm = m->connectionManager;
    m->width = 1920; m->height = 1080; m->usevirtualmon = 1;
    m->server_monitor_resize_done = resize_done;
    cm->_inited = true;
    cm->_mod = m;
    cm->_agentIpc = xipc_ctx_create(nullptr, cm);
    cm->_agentIpc->fd = sockets[0];
    assert(xipc_is_client_signed_by(cm->_agentIpc, "33X7M69J4B", "xrdp") != 0);
    cm->_statusManager.SetAgentRecordStart(false);

    monitor_info monitor = {};
    monitor.right = 2731; monitor.bottom = 2047; monitor.is_primary = 1;
    int pending = 123;
    assert(m->mod_server_monitor_resize(m, 2732, 2048, 1, &monitor, &pending) == 0);
    assert(pending == 1 && m->width == 2732 && m->height == 2048);
    assert(!cm->CanPaint() && !cm->CanAcceptInput());
    auto stop = packet(sockets[1]);
    auto start = packet(sockets[1]);
    assert(stop[0] == OSXRDP_CMDTYPE_SCREEN && stop[1] == OSXRDP_PACKETTYPE_REQ_RESIZE_STOP);
    assert(start[1] == OSXRDP_PACKETTYPE_REQ_SCREEN && start[3] == 2732 && start[4] == 2048);
    assert(start[8] == 1 && start[11] == 2731 && start[12] == 2047);
    assert(m->client_info.display_sizes.session_width == 2732);
    assert(m->client_info.display_sizes.minfo_wm[0].right == 2731);

    int reply[] = {OSXRDP_CMDTYPE_SCREEN, OSXRDP_PACKETTYPE_REP_SCREEN, 1};
    ConnectionManager::_OnReceivedAgentManagerMessage(cm->_agentIpc, nullptr, reply, sizeof(reply));
    assert(completed == 1 && cm->_resizePending && cm->_resizeCaptureReady);
    assert(!cm->CanPaint()); // No drawing before XRDP resets its encoder.
    cm->SetSuppress(true);
    assert(cm->_resizePending && !cm->CanPaint());

    // A concurrent or malformed resize must not mutate the accepted geometry.
    pending = 123;
    assert(m->mod_server_monitor_resize(m, 2048, 2732, 1, &monitor, &pending) != 0 && pending == 0);
    assert(m->width == 2732 && m->height == 2048);
    cm->_resizePending = false; cm->_resizeCaptureReady = false;
    cm->_statusManager.SetAgentRecordStart(false);
    assert(m->mod_server_monitor_resize(m, 10001, 2048, 1, &monitor, &pending) != 0);
    assert(m->mod_server_monitor_resize(m, 2732, 2048, 17, &monitor, &pending) != 0);
    assert(m->mod_server_monitor_resize(m, 2732, 2048, 1, nullptr, &pending) != 0);
    assert(m->mod_server_monitor_resize(m, 2732, 2048, 1, &monitor, nullptr) != 0);

    // Portrait resize and capture failure must finish the callback and terminate,
    // rather than leave XRDP waiting forever for a completion notification.
    monitor.right = 2047; monitor.bottom = 2731;
    assert(m->mod_server_monitor_resize(m, 2048, 2732, 1, &monitor, &pending) == 0);
    packet(sockets[1]); start = packet(sockets[1]);
    assert(start[3] == 2048 && start[4] == 2732);
    reply[2] = 0;
    ConnectionManager::_OnReceivedAgentManagerMessage(cm->_agentIpc, nullptr, reply, sizeof(reply));
    assert(completed == 2 && cm->NeedTerminate());
    cm->_resizePending = false;
    cm->_inited = false;
    xipc_destroy(cm->_agentIpc); cm->_agentIpc = nullptr;
    close(sockets[1]);
    mod_exit(m);
    puts("PASS: real resize callbacks, IPC stop/start, landscape/portrait geometry, graphics ordering, invalid requests, and failure completion");
}
