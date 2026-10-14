// Local fixture only: exchanges clipboard text, reads/writes a selected drive and resizes monitors.
#include "RDPFixtureChannels.h"
#include <freerdp/freerdp.h>
#include <freerdp/channels/channels.h>
#include <freerdp/server/cliprdr.h>
#include <freerdp/server/disp.h>
#include <freerdp/server/rdpdr.h>
#include <freerdp/settings.h>
#include <freerdp/channels/wtsvc.h>
#include <winpr/string.h>
#include <winpr/file.h>
#include <winpr/nt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
static pthread_mutex_t resize_lock = PTHREAD_MUTEX_INITIALIZER;
static UINT32 pending_width = 0, pending_height = 0;
static int closed_files = 0;
static HANDLE vcm;
static CliprdrServerContext* clip;
static DispServerContext* disp;
static RdpdrServerContext* drive;
static freerdp_peer* peer;
static BOOL started = FALSE, disp_started = FALSE, advertised = FALSE;
typedef struct { UINT32 device, file; BOOL writing; } FileRequest;
static FileRequest reading = {0}, writing = {.writing = TRUE};
static UINT clip_list(CliprdrServerContext* c, const CLIPRDR_FORMAT_LIST* list) {
    CLIPRDR_FORMAT_LIST_RESPONSE response = {.common = {.msgFlags = CB_RESPONSE_OK}};
    c->ServerFormatListResponse(c, &response);
    for (UINT32 j = 0; j < list->numFormats; j++) if (list->formats[j].formatId == 13) { CLIPRDR_FORMAT_DATA_REQUEST request = {.requestedFormatId = 13}; c->ServerFormatDataRequest(c, &request); break; }
    if (!advertised) { advertised = TRUE; CLIPRDR_FORMAT format = {.formatId = 13}; CLIPRDR_FORMAT_LIST remote = {.numFormats = 1, .formats = &format}; c->ServerFormatList(c, &remote); }
    return CHANNEL_RC_OK;
}
static UINT clip_request(CliprdrServerContext* c, const CLIPRDR_FORMAT_DATA_REQUEST* request) {
    size_t count = 0; WCHAR* text = ConvertUtf8ToWCharAlloc("REMOTE_CLIP_Привет", &count);
    CLIPRDR_FORMAT_DATA_RESPONSE response = {.common = {.msgFlags = request->requestedFormatId == 13 ? CB_RESPONSE_OK : CB_RESPONSE_FAIL, .dataLen = (UINT32)((count + 1) * 2)}, .requestedFormatData = (const BYTE*)text};
    UINT result = c->ServerFormatDataResponse(c, &response); free(text); return result;
}
static UINT clip_data(CliprdrServerContext* c, const CLIPRDR_FORMAT_DATA_RESPONSE* response) {
    (void)c;
    if (response->common.msgFlags == CB_RESPONSE_OK && response->common.dataLen <= 2097152 && response->common.dataLen % 2 == 0) {
        WCHAR* copy = calloc(1, response->common.dataLen + 2); memcpy(copy,response->requestedFormatData,response->common.dataLen);
        char* text = ConvertWCharToUtf8Alloc(copy,NULL); free(copy); if (text) { printf("CLIP_LOCAL %s\n",text); fflush(stdout); free(text); }
    }
    return CHANNEL_RC_OK;
}
static BOOL disp_assigned(DispServerContext* c, UINT32 channel) { (void)channel; return c->DisplayControlCaps(c) == CHANNEL_RC_OK; }
static UINT layout(DispServerContext* c, const DISPLAY_CONTROL_MONITOR_LAYOUT_PDU* pdu) {
    (void)c; UINT32 width = 0, height = 0;
    for (UINT32 j = 0; j < pdu->NumMonitors; j++) { width += pdu->Monitors[j].Width; if (pdu->Monitors[j].Height > height) height = pdu->Monitors[j].Height; }
    printf("LAYOUT %u %u %u\n",pdu->NumMonitors,width,height); fflush(stdout);
    pthread_mutex_lock(&resize_lock); pending_width = width; pending_height = height; pthread_mutex_unlock(&resize_lock); return CHANNEL_RC_OK;
}
static void drive_read(RdpdrServerContext* c, void* data, UINT32 status, const char* buffer, UINT32 length) {
    FileRequest* request = data; printf("DRIVE_READ %u %.*s\n",status,(int)length,buffer); fflush(stdout); c->DriveCloseFile(c,request,request->device,request->file);
}
static void drive_written(RdpdrServerContext* c, void* data, UINT32 status, UINT32 count) {
    FileRequest* request = data; printf("DRIVE_WRITE %u %u\n",status,count); fflush(stdout); c->DriveCloseFile(c,request,request->device,request->file);
}
static void drive_closed(RdpdrServerContext* c, void* data, UINT32 status) { (void)c; (void)data; (void)status; closed_files++; printf("DRIVE_CLOSED %d\n",closed_files); fflush(stdout); }
static void drive_opened(RdpdrServerContext* c, void* data, UINT32 status, UINT32 device, UINT32 file) {
    FileRequest* request = data; request->device = device; request->file = file;
    if (status != STATUS_SUCCESS) { printf("DRIVE_ERROR %u\n",status); fflush(stdout); return; }
    if (request->writing) c->DriveWriteFile(c,request,device,file,"WINDOWS_FILE_OK",15,0);
    else c->DriveReadFile(c,request,device,file,64,0);
}
static UINT drive_created(RdpdrServerContext* c, const RdpdrDevice* device) {
    printf("DRIVE %u %s\n",device->DeviceId,device->PreferredDosName); fflush(stdout);
    c->DriveOpenFile(c,&reading,device->DeviceId,"\\from-mac.txt",GENERIC_READ,FILE_OPEN);
    c->DriveOpenFile(c,&writing,device->DeviceId,"\\from-windows.txt",GENERIC_WRITE,FILE_CREATE);
    return CHANNEL_RC_OK;
}
BOOL fixture_channels_init(freerdp_peer* value) {
    peer = value;
    if (!WTSRegisterWtsApiFunctionTable(FreeRDP_InitWtsApi())) return FALSE;
    vcm = WTSOpenServerA((LPSTR)peer->context); return vcm != INVALID_HANDLE_VALUE && vcm != NULL;
}
BOOL fixture_channels_start(void) {
    if (started) return TRUE; started = TRUE;
    clip = cliprdr_server_context_new(vcm); if (!clip) return FALSE; clip->rdpcontext = peer->context; clip->useLongFormatNames = TRUE;
    clip->ClientFormatList = clip_list; clip->ClientFormatDataRequest = clip_request; clip->ClientFormatDataResponse = clip_data;
    if (clip->Start(clip) != CHANNEL_RC_OK) return FALSE;
    drive = rdpdr_server_context_new(vcm); if (!drive) return FALSE; drive->rdpcontext = peer->context;
    drive->supported = RDPDR_DTYP_FILESYSTEM; drive->OnDriveCreate = drive_created; drive->OnDriveOpenFileComplete = drive_opened; drive->OnDriveReadFileComplete = drive_read; drive->OnDriveWriteFileComplete = drive_written; drive->OnDriveCloseFileComplete = drive_closed;
    return drive->Start(drive) == CHANNEL_RC_OK;
}
BOOL fixture_channels_check(void) {
    if (!started || !peer->activated) return TRUE;
    if (!WTSVirtualChannelManagerCheckFileDescriptor(vcm)) return FALSE;
    if (!disp_started && WTSVirtualChannelManagerGetDrdynvcState(vcm) == DRDYNVC_STATE_READY) {
        disp_started = TRUE; disp = disp_server_context_new(vcm); if (!disp) return FALSE;
        disp->rdpcontext = peer->context; disp->MaxNumMonitors = 4; disp->MaxMonitorAreaFactorA = 8192; disp->MaxMonitorAreaFactorB = 2160; disp->ChannelIdAssigned = disp_assigned; disp->DispMonitorLayout = layout;
        if (disp->Open(disp) != CHANNEL_RC_OK) return FALSE;
    }
    pthread_mutex_lock(&resize_lock); UINT32 width = pending_width, height = pending_height; pending_width = pending_height = 0; pthread_mutex_unlock(&resize_lock);
    if (width) { freerdp_settings_set_uint32(peer->context->settings,FreeRDP_DesktopWidth,width); freerdp_settings_set_uint32(peer->context->settings,FreeRDP_DesktopHeight,height); if (!peer->context->update->DesktopResize(peer->context)) return FALSE; }
    return TRUE;
}
void fixture_channels_stop(void) { if (clip) { clip->Stop(clip); cliprdr_server_context_free(clip); }; if (drive) { drive->Stop(drive); rdpdr_server_context_free(drive); }; if (disp) disp_server_context_free(disp); if (vcm) WTSCloseServer(vcm); }
