"""Only sockets owned by this test; no Nmap install or user network required."""
import socket
import subprocess
import sys
import threading

listener = socket.socket()
listener.bind(('127.0.0.1', 0)); listener.listen(); listener.settimeout(.2)
closed = socket.socket()
closed.bind(('127.0.0.1', 0))
refused = str(closed.getsockname()[1])
# Darwin silently drops SYNs to a bound, non-listening TCP socket. Release
# our ephemeral port so the kernel actually returns ECONNREFUSED instead.
closed.close()
stop = threading.Event()


def serve():
    while not stop.is_set():
        try:
            connection, _ = listener.accept(); connection.close()
        except socket.timeout:
            pass
        except OSError:
            return


threading.Thread(target=serve, daemon=True).start()
try:
    opened = str(listener.getsockname()[1])
    for ports, mode in [(opened + ',' + refused, 'open'), (refused, 'closed'), (opened, 'cancel')]:
        subprocess.run([sys.argv[1], '--tcp-discovery', '127.0.0.1', ports, mode], check=True, timeout=8)
finally:
    stop.set(); listener.close(); closed.close()
print('PASS owned native discovery integration')
