import os,pty,termios,subprocess,sys,select,time,signal
helper=sys.argv[1]
master,slave=pty.openpty();device=os.ttyname(slave);original=termios.tcgetattr(slave)
p=subprocess.Popen([helper,device,'115200','8','none','1','none'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
def until(fd,wanted,timeout=4):
 result=b'';deadline=time.monotonic()+timeout
 while time.monotonic()<deadline:
  if select.select([fd],[],[],0.1)[0]:
   chunk=os.read(fd,8192)
   if not chunk:break
   result+=chunk
   if wanted in result:return result
 raise AssertionError((wanted,result,p.poll()))
try:
 until(p.stdout.fileno(),b'115200')
 os.write(master,'serial → console\r\n'.encode());until(p.stdout.fileno(),'serial → console'.encode())
 p.stdin.write(b'console-to-device\r');p.stdin.flush();until(master,b'console-to-device\r')
 second=subprocess.run([helper,device,'115200','8','none','1','none'],input=b'',capture_output=True,timeout=4)
 assert second.returncode!=0
 p.send_signal(signal.SIGTERM);p.wait(timeout=3);assert p.returncode==0
 # Darwin adds transient PENDIN when restoring canonical input; it is not a configured serial parameter.
 restored=termios.tcgetattr(slave);restored[3]&=~termios.PENDIN;original[3]&=~termios.PENDIN
 assert restored==original, 'serial settings not restored'
 testfd=os.open(device,os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK);os.close(testfd)
 bad=subprocess.run([helper,'/etc/passwd','115200','8','none','1','none'],capture_output=True,timeout=3)
 assert bad.returncode!=0
 print('Serial integration passed: PTY bidirectional Unicode/raw bytes, exclusive lock, graceful disconnect, termios restore and invalid path rejection; no physical device required')
finally:
 if p.poll() is None:p.kill();p.wait()
 os.close(master);os.close(slave)
