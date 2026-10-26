#include <sys/socket.h>
#include <sys/ioctl.h>
#include <netdb.h>
#include <termios.h>
#include <unistd.h>
#include <poll.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>
static volatile sig_atomic_t stopped = 0, resized = 1;
static void signal_stop(int n) { (void)n; stopped = 1; }
static void signal_resize(int n) { (void)n; resized = 1; }
static int write_all(int fd, const unsigned char* data, size_t count) {
    while (count && !stopped) { ssize_t n = write(fd,data,count); if (n < 0 && errno == EINTR) continue; if (n <= 0) return -1; data += n; count -= n; } return 0;
}
static void negotiate(int fd, unsigned char command, unsigned char option) { unsigned char bytes[3] = {255,command,option}; write_all(fd,bytes,3); }
static void window_size(int fd) {
    struct winsize size = {0}; if (ioctl(0,TIOCGWINSZ,&size) || !size.ws_col || !size.ws_row) { size.ws_col = 80; size.ws_row = 24; }
    unsigned char raw[4] = {size.ws_col >> 8,size.ws_col & 255,size.ws_row >> 8,size.ws_row & 255}, message[16] = {255,250,31}; size_t n = 3;
    for (int j = 0; j < 4; j++) { message[n++] = raw[j]; if (raw[j] == 255) message[n++] = 255; }
    message[n++] = 255; message[n++] = 240; write_all(fd,message,n);
}
int main(int argc, char** argv) {
    if (argc != 3) return 2;
    signal(SIGTERM,signal_stop); signal(SIGHUP,signal_stop); signal(SIGINT,signal_stop); signal(SIGWINCH,signal_resize); signal(SIGPIPE,SIG_IGN);
    struct addrinfo hint = {0}, *addresses = NULL; hint.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(argv[1],argv[2],&hint,&addresses)) { fprintf(stderr,"Telnet: не удалось определить адрес сервера\n"); return 1; }
    int fd = -1;
    for (struct addrinfo* a = addresses; a && !stopped; a = a->ai_next) {
        fd = socket(a->ai_family,a->ai_socktype,a->ai_protocol); if (fd < 0) continue;
        fcntl(fd,F_SETFL,O_NONBLOCK); int connected = connect(fd,a->ai_addr,a->ai_addrlen);
        if (connected < 0 && errno == EINPROGRESS) { struct pollfd wait = {fd,POLLOUT,0}; if (poll(&wait,1,15000) > 0) { int error = 0; socklen_t length = sizeof(error); getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&length); connected = error ? -1 : 0; } }
        if (connected == 0) { fcntl(fd,F_SETFL,0); break; } close(fd); fd = -1;
    }
    freeaddrinfo(addresses); if (fd < 0) { fprintf(stderr,"Telnet: сервер недоступен или отклонил порт\n"); return 1; }
    struct termios previous; int tty = tcgetattr(0,&previous) == 0;
    if (tty) { struct termios raw = previous; cfmakeraw(&raw); tcsetattr(0,TCSANOW,&raw); }
    int state = 0, command = 0, suboption = -1, subfirst = -1, naws = 0, binary = 0, result = 0, stdin_open = 1;
    while (!stopped) {
        if (resized && naws) { resized = 0; window_size(fd); }
        struct pollfd descriptors[2] = {{fd,POLLIN,0},{stdin_open ? 0 : -1,POLLIN,0}};
        int ready = poll(descriptors,2,200); if (ready < 0) { if (errno == EINTR) continue; result = 1; break; }
        if (descriptors[0].revents & (POLLIN|POLLHUP|POLLERR)) {
            unsigned char bytes[8192], display[8192]; ssize_t count = read(fd,bytes,sizeof(bytes)); size_t n = 0;
            if (count == 0) break; if (count < 0) { if (errno == EINTR) continue; result = 1; break; }
            for (ssize_t j = 0; j < count; j++) {
                unsigned char b = bytes[j];
                if (state == 0) { if (b == 255) state = 1; else display[n++] = b; }
                else if (state == 1) {
                    if (b == 255) { display[n++] = b; state = 0; }
                    else if (b >= 251 && b <= 254) { command = b; state = 2; }
                    else if (b == 250) { suboption = -1; subfirst = -1; state = 3; }
                    else state = 0;
                } else if (state == 2) {
                    if (command == 253) { int accept = b == 0 || b == 3 || b == 24 || b == 31; negotiate(fd,accept ? 251 : 252,b); if (b == 31 && accept) { naws = 1; window_size(fd); }; if (b == 0) binary = accept; }
                    else if (command == 251) { negotiate(fd,(b == 0 || b == 1 || b == 3) ? 253 : 254,b); }
                    else if (command == 254) { if (b == 31) naws = 0; if (b == 0) binary = 0; }
                    state = 0;
                } else if (state == 3) { if (b == 255) state = 4; else if (suboption < 0) suboption = b; else if (subfirst < 0) subfirst = b; }
                else if (state == 4) {
                    if (b == 240) { if (suboption == 24 && subfirst == 1) { const unsigned char terminal[] = {255,250,24,0,'x','t','e','r','m','-','2','5','6','c','o','l','o','r',255,240}; write_all(fd,terminal,sizeof(terminal)); }; state = 0; }
                    else state = 3;
                }
            }
            if (write_all(1,display,n)) break;
        }
        if (descriptors[1].revents & (POLLIN|POLLHUP)) {
            unsigned char bytes[4096], escaped[8192]; ssize_t count = read(0,bytes,sizeof(bytes)); size_t n = 0;
            if (count <= 0) { stdin_open = 0; continue; }
            for (ssize_t j = 0; j < count; j++) { escaped[n++] = bytes[j]; if (bytes[j] == 255) escaped[n++] = 255; else if (bytes[j] == '\r' && !binary && (j + 1 >= count || bytes[j+1] != '\n')) escaped[n++] = '\n'; }
            if (write_all(fd,escaped,n)) { result = 1; break; }
        }
    }
    if (tty) tcsetattr(0,TCSANOW,&previous); close(fd); return result;
}
