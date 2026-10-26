import Foundation
import Darwin

enum TrivyTarget: String, CaseIterable, Identifiable, Codable {
    case rootfs, filesystem, image
    var id: String { rawValue }
    var title: String { switch self { case .rootfs: return "Система / rootfs"; case .filesystem: return "Каталог проекта"; case .image: return "Образ контейнера" } }
}
struct SecurityRemoteRequest: Codable {
    var engine: SecurityEngine
    var mode = TrivyTarget.rootfs
    var target = "/"
    var minutes = 15
    var parallel = 1
    var valid: Bool {
        guard [.lynis, .trivy].contains(engine), (1...60).contains(minutes), (1...4).contains(parallel) else { return false }
        if engine == .lynis { return true }
        if mode == .image { return target.utf8.count <= 256 && SSHConfig.matches(target, "^[A-Za-z0-9][A-Za-z0-9._:/-]*(?:@sha256:[A-Fa-f0-9]{64})?$") && !target.contains("://") }
        return target.hasPrefix("/") && target.utf8.count <= 1024 && !target.split(separator: "/").contains("..") && SSHConfig.matches(target, "^/[A-Za-z0-9_./-]*$")
    }
    var parameters: String { engine == .lynis ? "Аудит системы; текущий пользователь SSH; без plugins; \(minutes) мин" : "\(mode.title): \(target); vuln,misconfig; параллельно \(parallel); \(minutes) мин" }
    func command() throws -> String {
        guard valid else { throw ConfigError.message("Проверь цель Trivy и лимиты: до 60 минут, 1–4 параллельные задачи.") }
        let data = try JSONEncoder().encode(self).base64EncodedString()
        return "python3 -c " + SSHConfig.shellQuote(SecurityAuditHelper.source) + " " + SSHConfig.shellQuote(data)
    }
    static func identityMatches(_ output: String, entry: SSHAlias) -> Bool {
        guard output.utf8.count <= 1_000_000 else { return false }
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let pair = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard pair.count == 2, ["hostname", "user", "port"].contains(String(pair[0])) else { continue }
            let key = String(pair[0]); guard fields[key] == nil else { return false }; fields[key] = String(pair[1])
        }
        return fields["hostname"]?.lowercased() == entry.host.lowercased() && fields["user"] == entry.user && fields["port"].flatMap(Int.init) == Int(entry.port)
    }
}
struct SecurityRemoteReply: Decodable {
    var schema: Int
    var engine: SecurityEngine
    var status: SecurityCheckStatus
    var message: String
    var rows: [Row]
    struct Row: Decodable { var rule: String; var title: String; var severity: String?; var cves: [String]; var score: Double?; var component: String; var evidence: String; var recommendation: String }
    static func parse(_ data: Data, engine: SecurityEngine) throws -> Self {
        guard data.count <= 8_000_000 else { throw ConfigError.message("Отчёт аудита превышает 8 МБ.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schema == 1, value.engine == engine, value.message.count <= 2000, value.rows.count <= 2000, value.findings.allSatisfy(\.valid) else { throw ConfigError.message("Некорректный ответ аудита.") }
        return value
    }
    var findings: [SecurityFinding] { rows.map { row in
        .init(rule: SecurityText.clean(row.rule, limit: 200), title: SecurityText.clean(row.title, limit: 500), severity: row.severity.flatMap { NucleiSeverity(rawValue: $0.lowercased()) },
              cves: Array(Set(row.cves.filter { SSHConfig.matches($0, "^CVE-[0-9]{4}-[0-9]{4,12}$") })).sorted(), score: row.score,
              component: SecurityText.clean(row.component, limit: 500), evidence: SecurityText.clean(row.evidence), recommendation: SecurityText.clean(row.recommendation, limit: 2000))
    } }
}

// A kept-open SSH stdin is the remote watchdog's lease. Closing it stops only
// the supervisor's new process group; give it time to return a partial report.
final class SecuritySSHRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var input: FileHandle?
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; let handle = input; input = nil; lock.unlock(); try? handle?.close() }
    func run(arguments: [String], environment: [String: String], timeout: TimeInterval, executable: URL = URL(fileURLWithPath: "/usr/bin/ssh")) throws -> (Data, Int32, Bool, Bool) {
        let child = Process(), stdin = Pipe(), out = Pipe(), err = Pipe()
        child.executableURL = executable; child.arguments = arguments; child.standardInput = stdin; child.standardOutput = out; child.standardError = err
        child.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        lock.lock(); if stopped { lock.unlock(); return (Data(), 0, true, false) }
        do { try child.run(); input = stdin.fileHandleForWriting; lock.unlock() } catch { lock.unlock(); throw error }
        defer { try? stdin.fileHandleForWriting.close(); lock.lock(); input = nil; lock.unlock() }
        let buffer = SecuritySSHBuffer()
        let handles = [(out.fileHandleForReading, false), (err.fileHandleForReading, true)]
        for (handle, _) in handles { let fd = handle.fileDescriptor; _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        defer { for (handle, _) in handles { try? handle.close() } }
        // Never wait for EOF from a proxy descendant that inherited a pipe.
        func drain() -> Bool {
            var received = false
            for (handle, isError) in handles {
                var bytes = [UInt8](repeating: 0, count: 65536)
                for _ in 0..<16 {
                    let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                    guard count > 0 else { break }
                    received = true
                    if !buffer.append(Data(bytes.prefix(count)), error: isError) { cancel(); break }
                }
            }
            return received
        }
        let deadline = Date().addingTimeInterval(timeout); var stopDate: Date?, expired = false
        while child.isRunning {
            _ = drain()
            if Date() >= deadline && !expired { expired = true; cancel() }
            lock.lock(); let stopping = stopped; lock.unlock()
            if stopping {
                if stopDate == nil { stopDate = Date() }
                let elapsed = Date().timeIntervalSince(stopDate!)
                if elapsed > 5 { child.terminate() }; if elapsed > 6 { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        child.waitUntilExit()
        for _ in 0..<16 { if !drain() { break } }
        lock.lock(); let cancelled = stopped; lock.unlock()
        let value = buffer.snapshot()
        guard !value.1 else { throw ConfigError.message("Ответ аудита превышает 8 МБ; процесс остановлен.") }
        return (value.0, child.terminationStatus, cancelled, expired)
    }
}
private final class SecuritySSHBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data(), diagnosticBytes = 0, overflow = false
    func append(_ data: Data, error: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if error { diagnosticBytes += data.count } else if output.count + data.count <= 8_000_000 { output.append(data) } else { overflow = true }
        if diagnosticBytes > 1_000_000 { overflow = true }; return !overflow
    }
    func snapshot() -> (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (output, overflow) }
}

enum SecurityAuditHelper {
    static let source = #"""
import os, sys, json, base64, re, time, signal, select, shutil, subprocess, tempfile
cfg=json.loads(base64.b64decode(sys.argv[1],validate=True))
engine=cfg.get('engine'); mode=cfg.get('mode'); target=cfg.get('target','')
minutes=cfg.get('minutes'); parallel=cfg.get('parallel')
if engine not in ('lynis','trivy') or type(minutes) is not int or not 1<=minutes<=60 or type(parallel) is not int or not 1<=parallel<=4: sys.exit(64)
if engine=='trivy':
    if mode not in ('rootfs','filesystem','image'): sys.exit(64)
    if mode=='image':
        if len(target)>256 or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:/-]*(?:@sha256:[A-Fa-f0-9]{64})?',target) or '://' in target: sys.exit(64)
    elif not re.fullmatch(r'/[A-Za-z0-9_./-]{0,1023}',target) or '..' in target.split('/'): sys.exit(64)
rows=[]; status='failed'; message='Аудит не завершён.'; child=None; requested=False; terminated=False
def clean(value,limit=500):
    text=str(value or '')
    if re.search(r'(?i)(password|passwd|secret|token|authorization|cookie|api[-_]?key)\s*[:=]',text):return '[Секретное значение скрыто]'
    return ''.join(c for c in text if ord(c)>=32 and ord(c)!=127)[:limit]
def row(rule,title,severity=None,component='',evidence='',recommendation='',cves=None,score=None):
    return dict(rule=clean(rule,200),title=clean(title),severity=severity,component=clean(component),evidence=clean(evidence,4000),recommendation=clean(recommendation,2000),cves=cves or [],score=score)
def terminate():
    global terminated
    if child is None or terminated:return
    terminated=True
    try:os.killpg(child.pid,signal.SIGTERM)
    except ProcessLookupError:return
    try:child.wait(timeout=1)
    except subprocess.TimeoutExpired:pass
    # The leader may exit while a descendant ignores TERM. Always finish the
    # new group, including after normal CLI exit, before deleting its files.
    try:os.killpg(child.pid,signal.SIGKILL)
    except ProcessLookupError:pass
    child.wait(timeout=2)
def stop_signal(*_):
    global requested
    requested=True
for signum in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT):signal.signal(signum,stop_signal)
with tempfile.TemporaryDirectory(prefix='ssh-hub-audit-') as directory:
    os.chmod(directory,0o700)
    report=os.path.join(directory,'report'); log=os.path.join(directory,'log')
    env=dict(PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/homebrew/bin',HOME=os.path.expanduser('~'),LANG='C',LC_ALL='C',TMPDIR=directory)
    binary=shutil.which(engine,path=env['PATH'])
    try:
        if not binary:
            message=engine+' не установлен на сервере. Установи CLI вручную и повтори проверку.'
        else:
            if engine=='lynis':
                profile=os.path.join(directory,'profile.prf')
                with open(profile,'w') as f:f.write('skip-upgrade-test=yes\n')
                args=[binary,'audit','system','--quick','--quiet','--no-colors','--no-plugins','--profile',profile,'--report-file',report,'--logfile',log]
            else:
                args=[binary,mode,'--config','/dev/null','--ignorefile','/dev/null','--format','json','--output',report,'--quiet','--no-progress','--scanners','vuln,misconfig','--list-all-pkgs=false','--parallel',str(parallel),'--timeout',str(minutes)+'m','--exit-code','0',target]
            with open(os.path.join(directory,'console'),'wb') as output:
                child=subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=output,stderr=output,env=env,cwd=directory,start_new_session=True)
                deadline=time.monotonic()+minutes*60
                while child.poll() is None:
                    ready=select.select([sys.stdin],[],[],0.15)[0]
                    if ready and not os.read(sys.stdin.fileno(),1):requested=True
                    if requested:status='stopped';message='Сохранены данные до остановки.';terminate();break
                    if time.monotonic()>=deadline:status='timeout';message='Достигнут лимит времени.';terminate();break
                    if any(os.path.exists(os.path.join(directory,n)) and os.path.getsize(os.path.join(directory,n))>16000000 for n in ('report','log','console')):
                        message='Превышен лимит вывода инструмента.';terminate();break
                else:
                    if child.returncode==0:status='completed';message='Проверка завершена.'
                    else:message='Инструмент завершился с кодом '+str(child.returncode)+'. Проверь установку, права и базы проверок.'
            if os.path.exists(report) and os.path.getsize(report)<=16000000:
                if engine=='lynis':
                    end=False; version=''; index=''
                    with open(report,encoding='utf-8',errors='replace') as f:
                        for line in f:
                            key,sep,value=line.rstrip('\n').partition('=')
                            if key=='report_datetime_end':end=True
                            if key=='lynis_version':version=clean(value,40)
                            if key=='hardening_index' and value.isdigit():index=value
                            if key in ('warning[]','suggestion[]'):
                                parts=value.split('|')
                                if len(parts)>=2:rows.append(row(parts[0],parts[1],evidence='Предупреждение' if key=='warning[]' else 'Рекомендация'))
                    if status=='completed' and not end:status='failed';message='Lynis не вернул признак завершения отчёта.'
                    if status=='completed' and os.geteuid()!=0:status='limited';message='Аудит без root: часть проверок недоступна. Для полного аудита выбери SSH-запись root.'
                    message+=' Lynis '+version+('. Индекс усиления: '+index+'/100.' if index else '')
                else:
                    with open(report,encoding='utf-8') as f:data=json.load(f)
                    if not isinstance(data,dict) or data.get('SchemaVersion')!=2 or not isinstance(data.get('Results',[]),list):raise ValueError('schema')
                    if not data.get('Results') and status=='completed':status='limited';message='Trivy не обнаружил поддерживаемых данных для проверки. Это не подтверждение безопасности цели.'
                    for result in data.get('Results',[]):
                        for item in result.get('Vulnerabilities') or []:
                            rule=str(item.get('VulnerabilityID',''))
                            cves=[rule] if re.fullmatch(r'CVE-[0-9]{4}-[0-9]{4,12}',rule) else []
                            cvss=item.get('CVSS') or {}; scores=[v.get('V3Score') for v in cvss.values() if isinstance(v,dict)]
                            scores=[n for n in scores if type(n) in (int,float) and 0<=n<=10]
                            rows.append(row(rule,item.get('Title') or rule,str(item.get('Severity','UNKNOWN')).lower(),item.get('PkgName'), 'Установлено: '+str(item.get('InstalledVersion','')), 'Исправлено: '+str(item.get('FixedVersion','')) if item.get('FixedVersion') else 'Исправленная версия не указана',cves,max(scores) if scores else None))
                        for item in result.get('Misconfigurations') or []:
                            rows.append(row(item.get('ID','config'),item.get('Title','Конфигурация'),str(item.get('Severity','UNKNOWN')).lower(),recommendation=item.get('Resolution','')))
            elif status=='completed':status='failed';message='Инструмент не создал полный отчёт.'
            if len(rows)>2000:
                rows=rows[:2000]
                if status=='completed':status='limited'
                message+=' Показаны первые 2000 находок.'
    except Exception:
        terminate();status='failed';message='Не удалось прочитать отчёт или запустить инструмент. Проверь совместимость CLI и права.'
    finally:
        terminate()
def encode():return json.dumps(dict(schema=1,engine=engine,status=status,message=clean(message,2000),rows=rows),ensure_ascii=True)
encoded=encode()
while len(encoded)>7500000 and rows:
    rows=rows[:len(rows)*3//4]
    if status=='completed':status='limited'
    message='Размер отчёта ограничен. Сохранена часть находок.'
    encoded=encode()
print(encoded,flush=True)
"""#
}
