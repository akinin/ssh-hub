// SSH Hub framebuffer bridge. FreeRDP is linked statically; its Apache-2.0 license is bundled.
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <errno.h>
#include <pthread.h>
#include "RDPChannels.h"
static pthread_mutex_t output_lock = PTHREAD_MUTEX_INITIALIZER;

static int dirty = 0;
static BOOL read_exact(void* buffer, size_t count) {
    unsigned char* p = buffer;
    while (count) { ssize_t n = read(0, p, count); if (n < 0 && errno == EINTR) continue; if (n <= 0) return FALSE; p += n; count -= n; }
    return TRUE;
}
static BOOL write_exact(const void* buffer, size_t count) {
    const unsigned char* p = buffer;
    while (count) { ssize_t n = write(1, p, count); if (n < 0 && errno == EINTR) continue; if (n <= 0) return FALSE; p += n; count -= n; }
    return TRUE;
}
static BOOL header(UINT32 type, UINT32 size) { UINT32 h[2] = {htonl(type), htonl(size)}; return write_exact(h, sizeof(h)); }
BOOL hub_message(UINT32 type, const void* bytes, UINT32 length) { pthread_mutex_lock(&output_lock); BOOL ok = header(type,length) && write_exact(bytes,length); pthread_mutex_unlock(&output_lock); return ok; }
static BOOL frame_unlocked(rdpContext* context) {
    rdpGdi* g = context->gdi;
    if (!g || g->width <= 0 || g->height <= 0 || g->width > 8192 || g->height > 2160 || (UINT64)g->width * g->height > 33000000) return FALSE;
    UINT32 size = (UINT32)g->width * (UINT32)g->height * 4;
    UINT32 dimensions[2] = {htonl(g->width), htonl(g->height)};
    if (!header(1, size + 8) || !write_exact(dimensions, 8)) return FALSE;
    for (int y = 0; y < g->height; y++) if (!write_exact(g->primary_buffer + y * g->stride, (size_t)g->width * 4)) return FALSE;
    return TRUE;
}
static BOOL frame(rdpContext* c) { pthread_mutex_lock(&output_lock); BOOL ok = frame_unlocked(c); pthread_mutex_unlock(&output_lock); return ok; }
static BOOL begin_paint(rdpContext* c) { c->gdi->primary->hdc->hwnd->invalid->null = TRUE; return TRUE; }
static BOOL end_paint(rdpContext* c) { if (!c->gdi->primary->hdc->hwnd->invalid->null) dirty = 1; return TRUE; }
static BOOL resize(rdpContext* c) {
    UINT32 w = freerdp_settings_get_uint32(c->settings, FreeRDP_DesktopWidth), h = freerdp_settings_get_uint32(c->settings, FreeRDP_DesktopHeight);
    if (w > 8192 || h > 2160 || w < 1 || h < 1 || (UINT64)w * h > 33000000) return FALSE;
    dirty = 1; return gdi_resize(c->gdi, w, h);
}
static BOOL post_connect(freerdp* instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;
    instance->context->update->BeginPaint = begin_paint;
    instance->context->update->EndPaint = end_paint;
    instance->context->update->DesktopResize = resize;
    dirty = 1; return TRUE;
}
static DWORD certificate(freerdp* i, const char* host, UINT16 port, const char* cn, const char* subject, const char* issuer, const char* fingerprint, DWORD flags) {
    (void)i; (void)cn; (void)subject; (void)issuer; (void)flags;
    char text[4096]; int n = snprintf(text, sizeof(text), "%s:%u\n%s", host, port, fingerprint ? fingerprint : "");
    if (n < 0 || n >= (int)sizeof(text) || !fingerprint || !*fingerprint || !hub_message(2, text, n)) return 0;
    UINT32 answer; if (!read_exact(&answer, 4)) return 0;
    return ntohl(answer) == 1 ? 2 : 0; // Trust this connection only; the app owns pinned fingerprints.
}
static DWORD changed_certificate(freerdp* i, const char* host, UINT16 port, const char* cn, const char* subject, const char* issuer, const char* fingerprint, const char* oldSubject, const char* oldIssuer, const char* oldFingerprint, DWORD flags) {
    (void)oldSubject; (void)oldIssuer; (void)oldFingerprint;
    return certificate(i, host, port, cn, subject, issuer, fingerprint, flags);
}
int main(int argc, char** argv) {
    if (argc != 8 && argc != 12) { fprintf(stderr, "RDP bridge: invalid settings\n"); return 2; }
    signal(SIGPIPE, SIG_IGN);
    WLog_SetLogLevel(WLog_GetRoot(), WLOG_ERROR);
    WLog_ConfigureAppender(WLog_GetLogAppender(WLog_GetRoot()), "outputstream", "stderr");
    UINT32 length; if (!read_exact(&length, 4)) return 2; length = ntohl(length);
    if (length > 4096) return 2;
    char password[4097] = {0}; if (!read_exact(password, length)) return 2;
    freerdp* i = freerdp_new(); if (!i || !freerdp_context_new(i)) return 2;
    i->PostConnect = post_connect; i->VerifyCertificateEx = certificate; i->VerifyChangedCertificateEx = changed_certificate;
    rdpSettings* s = i->context->settings;
    freerdp_settings_set_string(s, FreeRDP_ServerHostname, argv[1]);
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, (UINT32)atoi(argv[2]));
    freerdp_settings_set_string(s, FreeRDP_Username, argv[3]);
    freerdp_settings_set_string(s, FreeRDP_Domain, argv[4]);
    freerdp_settings_set_string(s, FreeRDP_Password, password); memset(password, 0, sizeof(password));
    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, (UINT32)atoi(argv[5]));
    freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, (UINT32)atoi(argv[6]));
    freerdp_settings_set_string(s, FreeRDP_ConfigPath, argv[7]);
    freerdp_settings_set_uint32(s, FreeRDP_TcpConnectTimeout, 15000);
    freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32);
    freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, FALSE);

    freerdp_settings_set_bool(s, FreeRDP_RdpSecurity, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_AutoReconnectionEnabled, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_CertificateCallbackPreferPEM, FALSE);
    if (!hub_channels_prepare(i, argc == 12 ? (UINT32)atoi(argv[8]) : 1, argc == 12 && atoi(argv[9]) != 0, argc == 12 ? argv[10] : "", argc == 12 ? (UINT32)atoi(argv[11]) : 0)) { fprintf(stderr, "RDP: invalid channel settings\n"); freerdp_context_free(i); freerdp_free(i); return 2; }
    if (!freerdp_connect(i)) {
        fprintf(stderr, "RDP: connection failed (0x%08x)\n", freerdp_get_last_error(i->context));
        freerdp_disconnect(i); freerdp_context_free(i); freerdp_free(i); return 1;
    }
    fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK);
    unsigned char input[16]; size_t used = 0; char* text_input = NULL; size_t text_length = 0, text_used = 0; BOOL running = TRUE;
    while (running && !freerdp_shall_disconnect_context(i->context)) {
        HANDLE handles[MAXIMUM_WAIT_OBJECTS]; DWORD count = freerdp_get_event_handles(i->context, handles, MAXIMUM_WAIT_OBJECTS);
        if (!count) break;
        DWORD event = WaitForMultipleObjects(count, handles, FALSE, 20);
        if (event == WAIT_FAILED) break;
        if (event != WAIT_TIMEOUT && !freerdp_check_event_handles(i->context)) break;
        if (dirty) { dirty = 0; if (!frame(i->context)) break; }
        while (running) {
            if (text_input) {
                ssize_t bytes = read(0, text_input + text_used, text_length - text_used);
                if (bytes < 0 && errno == EINTR) continue;
                if (bytes < 0 && errno == EAGAIN) break;
                if (bytes <= 0) { running = FALSE; break; }
                text_used += bytes;
                if (text_used == text_length) { text_input[text_length] = 0; hub_clipboard(text_input); free(text_input); text_input = NULL; }
                continue;
            }
            ssize_t n = read(0, input + used, sizeof(input) - used);
            if (n == 0) { running = FALSE; break; }
            if (n < 0) { if (errno == EINTR) continue; if (errno != EAGAIN) running = FALSE; break; }
            used += n; if (used != sizeof(input)) continue;
            UINT32 v[4]; memcpy(v, input, sizeof(v)); for (int j = 0; j < 4; j++) v[j] = ntohl(v[j]); used = 0;
            if (v[0] == 1) freerdp_input_send_mouse_event(i->context->input, v[1], v[2], v[3]);
            else if (v[0] == 2) freerdp_input_send_unicode_keyboard_event(i->context->input, v[1], v[2]);
            else if (v[0] == 3) freerdp_input_send_keyboard_event(i->context->input, v[1], v[2]);
            else if (v[0] == 4) running = FALSE;
            else if (v[0] == 5) { if (v[1] > 1024 * 1024) { running = FALSE; break; }; if (v[1] == 0) hub_clipboard(""); else { text_length = v[1]; text_used = 0; text_input = calloc(1, text_length + 1); if (!text_input) running = FALSE; } }
            else if (v[0] == 6) hub_request_clipboard();
            else if (v[0] == 7) hub_display(v[1],v[2],v[3]);
        }
    }
    free(text_input); freerdp_disconnect(i); hub_channels_free(); gdi_free(i); freerdp_context_free(i); freerdp_free(i); return 0;
}
