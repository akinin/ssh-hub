#include <freerdp/freerdp.h>
BOOL hub_message(UINT32 type, const void* bytes, UINT32 length);
BOOL hub_channels_prepare(freerdp* instance, UINT32 monitors, BOOL clipboard, const char* folder, UINT32 proxyPort);
void hub_clipboard(const char* text);
void hub_request_clipboard(void);
void hub_display(UINT32 width, UINT32 height, UINT32 monitors);
void hub_channels_free(void);
