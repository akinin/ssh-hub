// FreeRDP channel integration. Only Unicode text and an explicitly selected drive are redirected.
#include "RDPChannels.h"
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/channels.h>
#include <freerdp/addin.h>
#include <freerdp/event.h>
#include <freerdp/channels/channels.h>
#include <freerdp/settings.h>
#include <winpr/string.h>
#include <winpr/error.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static pthread_mutex_t channel_lock = PTHREAD_MUTEX_INITIALIZER;
static CliprdrClientContext* clipboard = NULL;
static DispClientContext* display = NULL;
static WCHAR* local_text = NULL;
static UINT32 local_bytes = 0;
static BOOL remote_unicode = FALSE, display_ready = FALSE, clipboard_ready = FALSE;
static UINT32 max_monitors = 1, area_a = 8192, area_b = 8192;

static UINT advertise(CliprdrClientContext* c) {
    CLIPRDR_FORMAT format = {.formatId = 13};
    CLIPRDR_FORMAT_LIST list = {.numFormats = 1, .formats = &format};
    return c->ClientFormatList(c, &list);
}
static UINT capabilities(CliprdrClientContext* c, const CLIPRDR_CAPABILITIES* caps) { (void)c; (void)caps; return CHANNEL_RC_OK; }
static UINT ready(CliprdrClientContext* c, const CLIPRDR_MONITOR_READY* event) {
    (void)event;
    CLIPRDR_GENERAL_CAPABILITY_SET general = {.capabilitySetType = CB_CAPSTYPE_GENERAL, .capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN, .version = CB_CAPS_VERSION_2, .generalFlags = CB_USE_LONG_FORMAT_NAMES};
    CLIPRDR_CAPABILITIES caps = {.cCapabilitiesSets = 1, .capabilitySets = (CLIPRDR_CAPABILITY_SET*)&general};
    UINT result = c->ClientCapabilities(c, &caps);
    pthread_mutex_lock(&channel_lock); clipboard_ready = TRUE; pthread_mutex_unlock(&channel_lock);
    return result == CHANNEL_RC_OK ? advertise(c) : result;
}
static UINT formats(CliprdrClientContext* c, const CLIPRDR_FORMAT_LIST* list) {
    BOOL unicode = FALSE;
    for (UINT32 j = 0; j < list->numFormats; j++) if (list->formats[j].formatId == 13) unicode = TRUE;
    pthread_mutex_lock(&channel_lock); remote_unicode = unicode; pthread_mutex_unlock(&channel_lock);
    CLIPRDR_FORMAT_LIST_RESPONSE response = {.common = {.msgFlags = CB_RESPONSE_OK}};
    UINT result = c->ClientFormatListResponse(c, &response);
    if (result == CHANNEL_RC_OK && unicode) { CLIPRDR_FORMAT_DATA_REQUEST request = {.requestedFormatId = 13}; result = c->ClientFormatDataRequest(c, &request); }
    return result;
}
static UINT format_response(CliprdrClientContext* c, const CLIPRDR_FORMAT_LIST_RESPONSE* response) { (void)c; (void)response; return CHANNEL_RC_OK; }
static UINT request(CliprdrClientContext* c, const CLIPRDR_FORMAT_DATA_REQUEST* request) {
    pthread_mutex_lock(&channel_lock);
    UINT32 length = local_bytes; BYTE* copy = length ? malloc(length) : NULL;
    if (copy) memcpy(copy, local_text, length);
    pthread_mutex_unlock(&channel_lock);
    CLIPRDR_FORMAT_DATA_RESPONSE response = {.common = {.msgFlags = CB_RESPONSE_FAIL}};
    if (request->requestedFormatId == 13 && copy) { response.common.msgFlags = CB_RESPONSE_OK; response.common.dataLen = length; response.requestedFormatData = copy; }
    UINT result = c->ClientFormatDataResponse(c, &response); free(copy); return result;
}
static UINT data(CliprdrClientContext* c, const CLIPRDR_FORMAT_DATA_RESPONSE* response) {
    (void)c;
    UINT32 length = response->common.dataLen;
    if (response->common.msgFlags != CB_RESPONSE_OK || !response->requestedFormatData || length < 2 || length > 2 * 1024 * 1024 || length % 2) return CHANNEL_RC_OK;
    WCHAR* text = calloc(1, length + 2); if (!text) return ERROR_NOT_ENOUGH_MEMORY;
    memcpy(text, response->requestedFormatData, length);
    size_t bytes = 0; char* utf8 = ConvertWCharToUtf8Alloc(text, &bytes); free(text);
    if (utf8) { size_t count = strnlen(utf8, 1024 * 1024 + 1); if (count <= 1024 * 1024) hub_message(3, utf8, (UINT32)count); free(utf8); }
    return CHANNEL_RC_OK;
}
static UINT disp_caps(DispClientContext* c, UINT32 monitors, UINT32 a, UINT32 b) {
    (void)c; pthread_mutex_lock(&channel_lock); max_monitors = monitors; area_a = a; area_b = b; display_ready = TRUE; pthread_mutex_unlock(&channel_lock);
    const char* message = "Изменение разрешения доступно"; hub_message(4, message, (UINT32)strlen(message)); return CHANNEL_RC_OK;
}
static void connected(void* context, const ChannelConnectedEventArgs* event) {
    (void)context;
    pthread_mutex_lock(&channel_lock);
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        clipboard = event->pInterface; clipboard->ServerCapabilities = capabilities; clipboard->MonitorReady = ready;
        clipboard->ServerFormatList = formats; clipboard->ServerFormatListResponse = format_response;
        clipboard->ServerFormatDataRequest = request; clipboard->ServerFormatDataResponse = data;
    } else if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0 || strcmp(event->name, DISP_CHANNEL_NAME) == 0) {
        display = event->pInterface; display->DisplayControlCaps = disp_caps;
    }
    pthread_mutex_unlock(&channel_lock);
}
static void disconnected(void* context, const ChannelDisconnectedEventArgs* event) {
    (void)context; pthread_mutex_lock(&channel_lock);
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) { clipboard = NULL; clipboard_ready = FALSE; }
    else if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0 || strcmp(event->name, DISP_CHANNEL_NAME) == 0) { display = NULL; display_ready = FALSE; }
    pthread_mutex_unlock(&channel_lock);
}
static BOOL load_channel(freerdp* i, const char* name, void* args) {
    PVIRTUALCHANNELENTRYEX entry = (PVIRTUALCHANNELENTRYEX)freerdp_load_channel_addin_entry(name,NULL,NULL,FREERDP_ADDIN_CHANNEL_STATIC | FREERDP_ADDIN_CHANNEL_ENTRYEX);
    if (!entry || freerdp_channels_client_load_ex(i->context->channels,i->context->settings,entry,args) != 0) { fprintf(stderr,"RDP: channel %s failed\n",name); return FALSE; }
    return TRUE;
}
static BOOL hub_load_channels(freerdp* i) {
    rdpSettings* s = i->context->settings;
    if (freerdp_settings_get_bool(s,FreeRDP_DeviceRedirection) && !load_channel(i,"rdpdr",s)) return FALSE;
    if (freerdp_settings_get_bool(s,FreeRDP_RedirectClipboard)) {
        const char* params[] = {"cliprdr"};
        if (!freerdp_client_add_static_channel(s,1,params) || !load_channel(i,"cliprdr",freerdp_static_channel_collection_find(s,"cliprdr"))) return FALSE;
    }
    const char* disp[] = {"disp"};
    if (!freerdp_client_add_dynamic_channel(s,1,disp)) return FALSE;
    freerdp_settings_set_bool(s,FreeRDP_SupportDynamicChannels,TRUE);
    return load_channel(i,"drdynvc",s);
}
BOOL hub_channels_prepare(freerdp* i, UINT32 monitors, BOOL enableClipboard, const char* folder, UINT32 proxyPort) {
    rdpSettings* s = i->context->settings;
    if (monitors < 1 || monitors > 4) return FALSE;
    UINT32 w = freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth), h = freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight);
    if (w * monitors > 8192 || (UINT64)w * h * monitors > 33000000) return FALSE;
    rdpMonitor definitions[4] = {0};
    for (UINT32 j = 0; j < monitors; j++) { definitions[j].x = (INT32)(j * w); definitions[j].width = (INT32)w; definitions[j].height = (INT32)h; definitions[j].is_primary = j == 0; definitions[j].orig_screen = j; definitions[j].attributes.desktopScaleFactor = 100; definitions[j].attributes.deviceScaleFactor = 100; }
    if (!freerdp_settings_set_monitor_def_array_sorted(s, definitions, monitors)) { fprintf(stderr,"RDP: monitor setup failed\n"); return FALSE; }
    freerdp_settings_set_bool(s, FreeRDP_UseMultimon, monitors > 1);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, w * monitors);
    freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, enableClipboard);
    if (folder && *folder) {
        const char* params[] = {"drive", "HubFiles", folder};
        if (!freerdp_client_add_device_channel(s, 3, params)) { fprintf(stderr,"RDP: selected drive setup failed\n"); return FALSE; }
        // Do not set RedirectDrives: that option also exposes automatically discovered media.
        freerdp_settings_set_bool(s, FreeRDP_DeviceRedirection, TRUE);
    }
    if (proxyPort) { freerdp_settings_set_uint32(s, FreeRDP_ProxyType, PROXY_TYPE_SOCKS); freerdp_settings_set_string(s, FreeRDP_ProxyHostname, "127.0.0.1"); freerdp_settings_set_uint16(s, FreeRDP_ProxyPort, (UINT16)proxyPort); }
    else freerdp_settings_set_uint32(s, FreeRDP_ProxyType, PROXY_TYPE_IGNORE);
    if (freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0) != CHANNEL_RC_OK) return FALSE;
    if (PubSub_SubscribeChannelConnected(i->context->pubSub, connected) < 0 || PubSub_SubscribeChannelDisconnected(i->context->pubSub, disconnected) < 0) { fprintf(stderr,"RDP: channel subscription failed\n"); return FALSE; }
    i->LoadChannels = hub_load_channels;
    return TRUE;
}
void hub_clipboard(const char* text) {
    size_t count = 0; WCHAR* value = ConvertUtf8ToWCharAlloc(text, &count); if (!value || count > 1024 * 1024) { free(value); return; }
    pthread_mutex_lock(&channel_lock); free(local_text); local_text = value; local_bytes = 0;
    local_bytes = (UINT32)((_wcslen(value) + 1) * 2);
    if (clipboard && clipboard_ready) advertise(clipboard);
    pthread_mutex_unlock(&channel_lock);
}
void hub_request_clipboard(void) { pthread_mutex_lock(&channel_lock); if (clipboard && clipboard_ready && remote_unicode) { CLIPRDR_FORMAT_DATA_REQUEST request = {.requestedFormatId = 13}; clipboard->ClientFormatDataRequest(clipboard, &request); } pthread_mutex_unlock(&channel_lock); }
void hub_display(UINT32 w, UINT32 h, UINT32 monitors) {
    if (w < 320 || h < 200 || w * monitors > 8192 || h > 2160 || monitors < 1 || monitors > 4 || (UINT64)w * h * monitors > 33000000) return;
    pthread_mutex_lock(&channel_lock);
    if (display && display_ready && monitors <= max_monitors && (UINT64)w * h * monitors <= (UINT64)area_a * area_b * max_monitors) {
        DISPLAY_CONTROL_MONITOR_LAYOUT layout[4] = {0};
        for (UINT32 j = 0; j < monitors; j++) { layout[j].Flags = j == 0 ? DISPLAY_CONTROL_MONITOR_PRIMARY : 0; layout[j].Left = (INT32)(j * w); layout[j].Width = w; layout[j].Height = h; layout[j].PhysicalWidth = 340; layout[j].PhysicalHeight = 270; layout[j].DesktopScaleFactor = 100; layout[j].DeviceScaleFactor = 100; }
        display->SendMonitorLayout(display, monitors, layout);
    }
    pthread_mutex_unlock(&channel_lock);
}
void hub_channels_free(void) { pthread_mutex_lock(&channel_lock); clipboard = NULL; display = NULL; free(local_text); local_text = NULL; pthread_mutex_unlock(&channel_lock); }
