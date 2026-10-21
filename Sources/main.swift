import Foundation
import CoreAudio
import AudioToolbox
import Network
import CoreImage

let usage = """
Usage: phoneear [--port N] [--keep-mac-audio]

  -p, --port N            Web page port (default 8765; audio uses N+1)
  -k, --keep-mac-audio    Don't mute the Mac's own speakers while streaming
  -h, --help              Show this help
"""

var httpPort: UInt16 = 8765
var keepMacAudio = false
var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "-p", "--port":
        guard let value = argIterator.next(), let p = UInt16(value), p < 65535 else { print(usage); exit(1) }
        httpPort = p
    case "-k", "--keep-mac-audio": keepMacAudio = true
    case "-h", "--help": print(usage); exit(0)
    default: print("Unknown option: \(arg)\n\n\(usage)"); exit(1)
    }
}
let wsPort = httpPort + 1

func log(_ message: String) {
    let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(time)] \(message)")
}

struct AudioError: LocalizedError {
    let what: String
    let status: OSStatus
    var errorDescription: String? { "\(what) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw AudioError(what: what, status: status) }
}

func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
    var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutableBytes(of: &value) {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
    }
    try check(status, "Reading audio property")
    return value
}

func defaultOutputDeviceUID() throws -> String {
    let device = try getProperty(
        AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0))
    let uid: Unmanaged<CFString>? = try getProperty(device, kAudioDevicePropertyDeviceUID, nil)
    guard let uid else { throw AudioError(what: "Reading output device UID", status: -1) }
    return uid.takeRetainedValue() as String
}

@inline(__always) func toInt16(_ x: Float) -> Int16 { Int16(max(-1, min(1, x)) * 32767) }

final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "phoneear.audio", qos: .userInteractive)
    private(set) var sampleRate: Double = 48_000

    func start(muteMac: Bool, onAudio: @escaping (Data, Bool) -> Void) throws {
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tap.uuid = UUID()
        tap.name = "PhoneEar"
        tap.isPrivate = true
        tap.muteBehavior = muteMac ? .muted : .unmuted
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "Creating system audio tap")

        let format = try getProperty(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        sampleRate = format.mSampleRate
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw AudioError(what: "Unexpected tap audio format", status: -1)
        }

        let outputUID = try defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PhoneEar Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tap.uuid.uuidString],
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating aggregate device")

        // Buffers arrive at the output device's rate, not the tap's reported format rate.
        let deviceRate = try getProperty(aggregateID, kAudioDevicePropertyNominalSampleRate, Float64(0))
        if deviceRate > 0 { sampleRate = deviceRate }

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            if let (pcm, audible) = Self.stereoInt16(input) { onAudio(pcm, audible) }
        }, "Creating audio callback")
        try check(AudioDeviceStart(aggregateID, procID), "Starting audio capture")
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func stereoInt16(_ input: UnsafePointer<AudioBufferList>) -> (Data, Bool)? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard buffers.count > 0, let first = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
        let channels = max(Int(buffers[0].mNumberChannels), 1)
        let frames = Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return nil }
        let second = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil

        var audible = false
        var data = Data(count: frames * 4)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let left: Float, right: Float
                if channels >= 2 {
                    left = first[i * channels]; right = first[i * channels + 1]
                } else if let second {
                    left = first[i]; right = second[i]
                } else {
                    left = first[i]; right = left
                }
                if left != 0 || right != 0 { audible = true }
                out[i * 2] = toInt16(left)
                out[i * 2 + 1] = toInt16(right)
            }
        }
        return (data, audible)
    }
}

final class Server {
    private let queue = DispatchQueue(label: "phoneear.net", qos: .userInteractive)
    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var inFlight: [ObjectIdentifier: Int] = [:]
    private var skipped = 0
    private let page: Data
    private let hello: String
    private let binary = NWConnection.ContentContext(
        identifier: "pcm", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
    private let text = NWConnection.ContentContext(
        identifier: "hello", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])

    init(page: String, sampleRate: Double) {
        self.page = Data(page.utf8)
        self.hello = #"{"rate":\#(Int(sampleRate))}"#
    }

    func start(httpPort: UInt16, wsPort: UInt16) throws {
        let httpListener = try NWListener(using: Self.tcpParameters(), on: NWEndpoint.Port(rawValue: httpPort)!)
        httpListener.newConnectionHandler = { [weak self] in self?.serveHTTP($0) }
        httpListener.stateUpdateHandler = { Self.exitOnFailure($0, port: httpPort) }
        httpListener.start(queue: queue)
        self.httpListener = httpListener

        let wsParameters = Self.tcpParameters()
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsParameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        let wsListener = try NWListener(using: wsParameters, on: NWEndpoint.Port(rawValue: wsPort)!)
        wsListener.newConnectionHandler = { [weak self] in self?.acceptWebSocket($0) }
        wsListener.stateUpdateHandler = { Self.exitOnFailure($0, port: wsPort) }
        wsListener.start(queue: queue)
        self.wsListener = wsListener
    }

    func broadcast(_ pcm: Data) {
        queue.async { [self] in
            for (id, connection) in clients {
                guard inFlight[id, default: 0] < 150 else { skipped += 1; continue }
                inFlight[id, default: 0] += 1
                connection.send(content: pcm, contentContext: binary, isComplete: true,
                                completion: .contentProcessed { [weak self] _ in self?.inFlight[id, default: 1] -= 1 })
            }
        }
    }

    private static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private static func exitOnFailure(_ state: NWListener.State, port: UInt16) {
        guard case .failed(let error) = state else { return }
        print("❌ Couldn't listen on port \(port): \(error). Try another one with --port.")
        exit(1)
    }

    private func serveHTTP(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [page] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let found = path == "/" || path.hasPrefix("/?")
            let body = found ? page : Data("Not found".utf8)
            var response = Data("""
                HTTP/1.1 \(found ? "200 OK" : "404 Not Found")\r
                Content-Type: \(found ? "text/html; charset=utf-8" : "text/plain")\r
                Content-Length: \(body.count)\r
                Cache-Control: no-store\r
                Connection: close\r
                \r

                """.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func acceptWebSocket(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                clients[id] = connection
                connection.send(content: Data(hello.utf8), contentContext: text, isComplete: true, completion: .idempotent)
                log("📱 Phone connected (\(clients.count) listening)")
                receive(on: connection)
            case .failed, .cancelled:
                connection.cancel()
                inFlight[id] = nil
                if clients.removeValue(forKey: id) != nil { log("📴 Phone disconnected (\(clients.count) listening)") }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close {
                connection.cancel()
                return
            }
            if metadata?.opcode == .text, let data { self?.logHealth(data, from: ObjectIdentifier(connection)) }
            self?.receive(on: connection)
        }
    }

    private struct Health: Decodable { let underruns, drops, maxGap, buffered, target: Int; let sampleRate: Double }
    private var lastGlitches: [ObjectIdentifier: Int] = [:]

    private func logHealth(_ data: Data, from id: ObjectIdentifier) {
        guard let health = try? JSONDecoder().decode(Health.self, from: data) else { return }
        let glitches = health.underruns + health.drops
        guard lastGlitches[id] != glitches else { return }
        lastGlitches[id] = glitches
        log("📊 Phone: \(health.underruns) underruns, \(health.drops) catch-up skips, "
            + "buffer \(health.buffered)/\(health.target) ms, longest Wi-Fi gap \(health.maxGap) ms, "
            + "phone audio \(Int(health.sampleRate)) Hz, Mac-side skips \(skipped)")
    }
}

func localIPv4Address() -> String? {
    var addresses: [(name: String, ip: String)] = []
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let interface = pointer.pointee
        guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
              interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { continue }
        addresses.append((String(cString: interface.ifa_name), String(cString: host)))
    }
    return (addresses.first { $0.name == "en0" } ?? addresses.first { $0.name.hasPrefix("en") } ?? addresses.first)?.ip
}

func printQRCode(_ text: String) {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("L", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage else { return }
    let width = Int(image.extent.width), height = Int(image.extent.height)
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    CIContext().render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: image.extent,
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

    let margin = 2
    func dark(_ x: Int, _ y: Int) -> Bool {
        let (px, py) = (x - margin, y - margin)
        guard px >= 0, py >= 0, px < width, py < height else { return false }
        return pixels[(py * width + px) * 4] < 128
    }
    for y in stride(from: 0, to: height + margin * 2, by: 2) {
        var line = "  \u{1B}[30;47m"
        for x in 0..<(width + margin * 2) {
            switch (dark(x, y), dark(x, y + 1)) {
            case (true, true): line += "█"
            case (true, false): line += "▀"
            case (false, true): line += "▄"
            case (false, false): line += " "
            }
        }
        print(line + "\u{1B}[0m")
    }
}

let pageTemplate = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#0c0c0e">
<title>PhoneEar</title>
<style>
  :root { --bg:#0c0c0e; --fg:#f2f2f4; --dim:#8a8a93; --line:#26262c; --accent:#5eead4; --warn:#fbbf24; }
  * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
  html, body { margin:0; height:100%; background:var(--bg); color:var(--fg);
    font:16px/1.4 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
  main { min-height:100%; display:flex; flex-direction:column; align-items:center; justify-content:center; gap:28px;
    padding:max(24px, env(safe-area-inset-top)) 24px max(24px, env(safe-area-inset-bottom)); }
  h1 { margin:0; font-size:15px; font-weight:600; letter-spacing:.14em; text-transform:uppercase; color:var(--dim); }
  #go { width:200px; height:200px; border-radius:50%; border:1px solid var(--line); background:#151519; color:var(--fg);
    font:600 19px/1.2 inherit; cursor:pointer; position:relative; transition:transform .15s ease, border-color .3s ease;
    -webkit-user-select:none; user-select:none; touch-action:manipulation; }
  #go:active { transform:scale(.96); }
  #go.on { border-color:var(--accent); box-shadow:0 0 0 1px var(--accent) inset; }
  #go.on::after { content:""; position:absolute; inset:-1px; border-radius:50%; border:1px solid var(--accent);
    animation:pulse 2s ease-out infinite; }
  @keyframes pulse { from { transform:scale(1); opacity:.6 } to { transform:scale(1.25); opacity:0 } }
  @media (prefers-reduced-motion: reduce) { #go.on::after { animation:none; } }
  #status { display:flex; align-items:center; gap:8px; color:var(--dim); font-size:14px; min-height:20px; }
  #dot { width:8px; height:8px; border-radius:50%; background:var(--warn); }
  #dot.live { background:var(--accent); }
  .controls { width:100%; max-width:340px; display:grid; gap:18px; }
  label { display:grid; gap:8px; font-size:13px; color:var(--dim); }
  label span { display:flex; justify-content:space-between; }
  label b { color:var(--fg); font-weight:500; font-variant-numeric:tabular-nums; }
  input[type=range] { width:100%; accent-color:var(--accent); }
  .tip { max-width:340px; font-size:12.5px; color:var(--dim); text-align:center; margin:0; }
</style>
</head>
<body>
<main>
  <h1>PhoneEar</h1>
  <button id="go">Tap to listen</button>
  <div id="status"><i id="dot"></i><span id="msg">Connecting…</span></div>
  <div class="controls">
    <label><span>Volume <b id="volv"></b></span><input id="vol" type="range" min="0" max="150" step="1"></label>
    <label><span>Buffer (lower = less delay, higher = fewer dropouts) <b id="bufv"></b></span>
      <input id="buf" type="range" min="60" max="600" step="10"></label>
  </div>
  <p class="tip">Keep this page open and the screen on — iPhone pauses web audio when locked.</p>
</main>
<script>
const WS_PORT = __WS_PORT__;
const $ = id => document.getElementById(id);
const saved = (key, fallback) => { try { return Number(localStorage.getItem(key)) || fallback; } catch { return fallback; } };
const save = (key, value) => { try { localStorage.setItem(key, value); } catch {} };

let ctx, gain, node, ws, rate = 48000, playing = false, connected = false;
let target = saved('buffer-v3', 120) / 1000;
const MIN_TARGET = 0.06, MAX_TARGET = 0.6;
let cleanSince = 0;

const RING = 48000 * 4;
const ringL = new Float32Array(RING), ringR = new Float32Array(RING);
let writePos = 0, readPos = 0, priming = true;
const stats = { underruns: 0, drops: 0, maxGap: 0, lastPacket: 0 };
const buffered = () => writePos - readPos;
let volume = saved('vol', 100) / 100;

$('buf').value = target * 1000; $('bufv').textContent = Math.round(target * 1000) + ' ms';
$('vol').value = volume * 100;  $('volv').textContent = Math.round(volume * 100) + '%';
$('buf').oninput = e => { target = e.target.value / 1000; $('bufv').textContent = e.target.value + ' ms';
  save('buffer-v3', e.target.value); cleanSince = performance.now(); };
$('vol').oninput = e => { volume = e.target.value / 100; $('volv').textContent = e.target.value + '%';
  if (gain) gain.gain.value = volume; save('vol', e.target.value); };

function setStatus(text, live) { $('msg').textContent = text; $('dot').className = live ? 'live' : ''; }

function connect() {
  ws = new WebSocket(`ws://${location.hostname}:${WS_PORT}`);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => { connected = true; setStatus(playing ? 'Playing' : 'Connected — tap to listen', true); };
  ws.onclose = () => { connected = false; setStatus('Mac not reachable — retrying…', false); setTimeout(connect, 1000); };
  ws.onmessage = e => {
    if (typeof e.data === 'string') { rate = JSON.parse(e.data).rate || 48000; return; }
    if (!playing) return;
    const now = performance.now();
    if (stats.lastPacket) stats.maxGap = Math.max(stats.maxGap, now - stats.lastPacket);
    stats.lastPacket = now;
    push(new Int16Array(e.data));
  };
}

function push(pcm) {
  const frames = pcm.length >> 1;
  for (let i = 0, j = 0; i < frames; i++, j += 2) {
    const k = (writePos + i) % RING;
    ringL[k] = pcm[j] / 32768;
    ringR[k] = pcm[j + 1] / 32768;
  }
  writePos += frames;
  if (buffered() > (target + 0.4) * rate) { readPos = writePos - target * rate; stats.drops++; }
}

function pull(e) {
  const outL = e.outputBuffer.getChannelData(0), outR = e.outputBuffer.getChannelData(1);
  outL.fill(0); outR.fill(0);
  if (!playing) return;
  if (priming) {
    if (buffered() < target * rate) return;
    priming = false;
  }
  const error = (buffered() / rate - target) / target;
  const step = (rate / ctx.sampleRate) * (1 + Math.max(-0.003, Math.min(0.003, error * 0.003)));
  for (let i = 0; i < outL.length; i++) {
    if (readPos + 1 >= writePos) {
      priming = true; stats.underruns++; cleanSince = performance.now();
      target = Math.min(MAX_TARGET, target + 0.04);
      return;
    }
    const p = Math.floor(readPos), f = readPos - p, a = p % RING, b = (p + 1) % RING;
    outL[i] = ringL[a] + (ringL[b] - ringL[a]) * f;
    outR[i] = ringR[a] + (ringR[b] - ringR[a]) * f;
    readPos += step;
  }
}

function restart() { readPos = writePos; priming = true; stats.lastPacket = 0; }

$('go').onclick = async () => {
  if (!ctx) {
    try { if (navigator.audioSession) navigator.audioSession.type = 'playback'; } catch {}
    ctx = new (window.AudioContext || window.webkitAudioContext)();
    gain = ctx.createGain();
    gain.gain.value = volume;
    node = ctx.createScriptProcessor(2048, 1, 2);
    node.onaudioprocess = pull;
    node.connect(gain);
    gain.connect(ctx.destination);
  }
  playing = !playing;
  if (playing) { restart(); await ctx.resume(); } else { await ctx.suspend(); }
  $('go').textContent = playing ? 'Listening' : 'Tap to listen';
  $('go').classList.toggle('on', playing);
  setStatus(connected ? (playing ? 'Playing' : 'Paused') : 'Mac not reachable — retrying…', connected);
};

document.addEventListener('visibilitychange', () => {
  if (!document.hidden && ctx && playing) { restart(); ctx.resume(); }
});

setInterval(() => {
  if (!ctx || !playing || !connected) return;
  const now = performance.now();
  if (!cleanSince) cleanSince = now;
  if (now - cleanSince > 15000 && target > MIN_TARGET) {
    target = Math.max(MIN_TARGET, target - 0.01);
    cleanSince = now;
  }
  const delay = buffered() / rate + 2048 / ctx.sampleRate + (ctx.baseLatency || 0) + (ctx.outputLatency || 0);
  const ms = Math.round(target * 1000);
  if (Number($('buf').value) !== ms) { $('buf').value = ms; $('bufv').textContent = ms + ' ms'; save('buffer-v3', ms); }
  const glitches = stats.underruns + stats.drops;
  setStatus(`Playing · ~${Math.round(delay * 1000)} ms behind${glitches ? ` · ${glitches} dropouts` : ''}`, true);
}, 500);

setInterval(() => {
  if (!ctx || !playing || ws.readyState !== 1) return;
  ws.send(JSON.stringify({ underruns: stats.underruns, drops: stats.drops, maxGap: Math.round(stats.maxGap),
    buffered: Math.round(buffered() / rate * 1000), target: Math.round(target * 1000), sampleRate: ctx.sampleRate }));
  stats.maxGap = 0;
}, 2000);

connect();
</script>
</body>
</html>
"""#

setvbuf(stdout, nil, _IONBF, 0)

let tap = SystemAudioTap()
var server: Server!
var heardAudio = false
var pending = Data()
let packetBytes = 960 * 4

do {
    try tap.start(muteMac: !keepMacAudio) { pcm, audible in
        if audible { heardAudio = true }
        pending.append(pcm)
        guard pending.count >= packetBytes else { return }
        server?.broadcast(pending)
        pending = Data()
    }
    let page = pageTemplate.replacingOccurrences(of: "__WS_PORT__", with: String(wsPort))
    server = Server(page: page, sampleRate: tap.sampleRate)
    try server.start(httpPort: httpPort, wsPort: wsPort)
} catch {
    tap.stop()
    print("❌ \(error.localizedDescription)")
    exit(1)
}

let ip = localIPv4Address() ?? "<your-mac-ip>"
let url = "http://\(ip):\(httpPort)"
print("""

  🎧 PhoneEar is running  (\(Int(tap.sampleRate)) Hz stereo\(keepMacAudio ? "" : ", Mac speakers muted"))

  On your iPhone (same Wi-Fi), open Safari at:

      \(url)

  …or point the iPhone camera at this:

""")
printQRCode(url)
print("\n  Press Ctrl+C to stop.\n")

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        tap.stop()
        print("\n👋 Stopped. Mac audio is back to normal.")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
    guard !heardAudio else { return }
    log("""
        ⚠️  Still only silence from the Mac. If something is playing, macOS may be blocking capture:
            System Settings → Privacy & Security → Screen & System Audio Recording →
            "System Audio Recording Only" → turn on Terminal (or your terminal app), then restart PhoneEar.
        """)
}

dispatchMain()
