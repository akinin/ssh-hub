// Local-only RDP integration fixture, using the same bundled FreeRDP core.
#include <freerdp/peer.h>
#include <freerdp/freerdp.h>
#include <freerdp/crypto/privatekey.h>
#include <freerdp/crypto/certificate.h>
#include <freerdp/settings.h>
#include <freerdp/input.h>
#include <freerdp/update.h>
#include <freerdp/primary.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
static BOOL post(freerdp_peer* peer) { (void)peer; return TRUE; }
static BOOL activate(freerdp_peer* peer) {
    OPAQUE_RECT_ORDER rect = {0}; rect.nWidth = 320; rect.nHeight = 200; rect.color = 0x112233;
    peer->context->update->BeginPaint(peer->context);
    peer->context->update->primary->OpaqueRect(peer->context, &rect);
    peer->context->update->EndPaint(peer->context);
    puts("ACTIVE"); fflush(stdout); return TRUE;
}
static BOOL mouse(rdpInput* input, UINT16 flags, UINT16 x, UINT16 y) { (void)input; printf("MOUSE %u %u %u\n",flags,x,y); fflush(stdout); return TRUE; }
static BOOL keyboard(rdpInput* input, UINT16 flags, UINT8 code) { (void)input; printf("KEY %u %u\n",flags,code); fflush(stdout); return TRUE; }
static BOOL unicode_key(rdpInput* input, UINT16 flags, UINT16 code) { (void)input; printf("UNICODE %u %u\n",flags,code); fflush(stdout); return TRUE; }
int main(int argc, char** argv) {
    if (argc != 3 && argc != 4) return 2;
    signal(SIGPIPE,SIG_IGN);
    WLog_SetLogLevel(WLog_GetRoot(), WLOG_ERROR); WLog_ConfigureAppender(WLog_GetLogAppender(WLog_GetRoot()),"outputstream","stderr");
    int listener = socket(AF_INET, SOCK_STREAM, 0); struct sockaddr_in address = {0}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener,(struct sockaddr*)&address,sizeof(address)) || listen(listener,1)) return 2;
    socklen_t size = sizeof(address); getsockname(listener,(struct sockaddr*)&address,&size); printf("PORT %u\n",ntohs(address.sin_port)); fflush(stdout);
    int fd = accept(listener,NULL,NULL); close(listener); if (fd < 0) return 2;
    freerdp_peer* p = freerdp_peer_new(fd); if (!p || !freerdp_peer_context_new(p)) return 2;
    rdpSettings* s = p->context->settings;
    freerdp_settings_set_pointer_len(s,FreeRDP_RdpServerRsaKey,freerdp_key_new_from_file_enc(argv[2],NULL),1);
    freerdp_settings_set_pointer_len(s,FreeRDP_RdpServerCertificate,freerdp_certificate_new_from_file(argv[1]),1);
    freerdp_settings_set_bool(s,FreeRDP_NlaSecurity,FALSE); freerdp_settings_set_bool(s,FreeRDP_TlsSecurity,TRUE); freerdp_settings_set_bool(s,FreeRDP_RdpSecurity,FALSE);
    freerdp_settings_set_bool(s,FreeRDP_ExtSecurity,FALSE); freerdp_settings_set_bool(s,FreeRDP_RdstlsSecurity,FALSE);
    if (argc == 4) { freerdp_settings_set_bool(s,FreeRDP_NlaSecurity,TRUE); freerdp_settings_set_string(s,FreeRDP_NtlmSamFile,argv[3]); }
    freerdp_settings_set_uint32(s,FreeRDP_DesktopWidth,640); freerdp_settings_set_uint32(s,FreeRDP_DesktopHeight,480); freerdp_settings_set_uint32(s,FreeRDP_ColorDepth,32);
    p->PostConnect = post; p->Activate = activate;
    if (!p->Initialize(p)) return 2;
    p->context->input->MouseEvent = mouse; p->context->input->KeyboardEvent = keyboard; p->context->input->UnicodeKeyboardEvent = unicode_key;
    while (1) {
        HANDLE handles[64]; DWORD count = p->GetEventHandles(p,handles,64); if (!count) break;
        DWORD status = WaitForMultipleObjects(count,handles,FALSE,1000); if (status == WAIT_FAILED) break;
        if (status != WAIT_TIMEOUT && !p->CheckFileDescriptor(p)) break;
    }
    p->Disconnect(p); freerdp_peer_context_free(p); freerdp_peer_free(p); return 0;
}
