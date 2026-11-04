import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'clock.dart';
import 'protocol.dart';

/// 超过此时间未收到对方任何消息即视为断开；双方每秒至少互发一次
const _silenceTimeoutUs = 8000000;

/// 一条控制连接（TCP），按行收发 JSON
class Connection {
  Connection(
    this._socket, {
    required void Function(Connection, Message) onMessage,
    required void Function(Connection) onClosed,
  }) : address = _socket.remoteAddress.address,
       _onClosed = onClosed {
    try {
      _socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    // 写入失败经由 done 报告，由读取端的结束处理关闭
    _socket.done.then((_) {}, onError: (_) {});
    _subscription = utf8.decoder
        .bind(_socket)
        .transform(const LineSplitter())
        .listen(
          (line) {
            lastReceived = nowUs;
            if (Protocol.decode(line) case final message?) {
              onMessage(this, message);
            }
          },
          onDone: close,
          onError: (_) => close(),
          cancelOnError: true,
        );
  }

  final Socket _socket;
  final String address;
  final void Function(Connection) _onClosed;
  late final StreamSubscription<String> _subscription;
  bool _closed = false;

  bool get isClosed => _closed;

  int lastReceived = nowUs;

  void send(Map<String, Object?> message) {
    if (_closed) return;
    try {
      _socket.write('${Protocol.encode(message)}\n');
    } catch (_) {
      close();
    }
  }

  /// 关闭连接；返回的 Future 在已写入的消息发出（或超时）后完成
  Future<void> close() {
    if (_closed) return _closing;
    _closed = true;
    _subscription.cancel();
    // 先发出已写入的消息（如停止）再断开
    _closing = _socket
        .close()
        .timeout(const Duration(seconds: 2))
        .then((_) {}, onError: (_) {})
        .whenComplete(_socket.destroy);
    _onClosed(this);
    return _closing;
  }

  Future<void> _closing = Future.value();
}

/// 发现用的 UDP 套接字，网络变化后可重新绑定
class _Discovery {
  _Discovery(this._onMessage);

  static const _refreshUs = 10000000;

  static final _limited = InternetAddress('255.255.255.255');

  /// 桌面端常有多块网卡（虚拟机、WSL、VPN 等），系统只从其中一块发出受限广播：
  /// 另从绑定各网卡地址的套接字分别广播
  static final _perInterface =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// 收到的消息及来源地址、端口
  final void Function(Message message, InternetAddress from, int port)
  _onMessage;
  RawDatagramSocket? _socket;
  List<InternetAddress> _targets = [_limited];
  int _targetsAt = -_refreshUs;

  /// 各网卡地址上的发送套接字；对方回应到其端口的单播也经此收到（防火墙放行
  /// 对广播的回应，未放行入站时仍能发现音源）
  final Map<String, RawDatagramSocket> _senders = {};

  Future<void> bind() async {
    close();
    _targetsAt = -_refreshUs;
    _binding = true;
    final RawDatagramSocket socket;
    try {
      socket = _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        Protocol.discoveryPort,
        reuseAddress: true,
      );
    } finally {
      _binding = false;
    }
    socket
      ..broadcastEnabled = true
      ..listen(
        (event) {
          if (event == RawSocketEvent.read) _receive(socket);
        },
        onError: (_) {},
        // 系统可能关闭后台应用的套接字，由定时检查重新绑定
        onDone: () {
          if (identical(_socket, socket)) _socket = null;
        },
      );
  }

  bool _binding = false;

  /// 已绑定或正在绑定
  bool get isOpen => _socket != null || _binding;

  void close() {
    _socket?.close();
    _socket = null;
    for (final sender in _senders.values) {
      sender.close();
    }
    _senders.clear();
  }

  void _receive(RawDatagramSocket socket) {
    for (
      var datagram = socket.receive();
      datagram != null;
      datagram = socket.receive()
    ) {
      try {
        final message = Protocol.decode(utf8.decode(datagram.data));
        if (message != null && message['app'] == Protocol.app) {
          _onMessage(message, datagram.address, datagram.port);
        }
      } catch (_) {}
    }
  }

  static List<int> _encode(Map<String, Object?> message) =>
      utf8.encode(Protocol.encode({'app': Protocol.app, ...message}));

  void send(
    Map<String, Object?> message,
    InternetAddress address, {
    int port = Protocol.discoveryPort,
  }) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.send(_encode(message), address, port);
    } catch (_) {}
  }

  /// 广播到受限广播地址及各 IPv4 网卡按 /24 推算的子网广播地址；桌面端另从
  /// 各网卡分别广播
  Future<void> broadcast(Map<String, Object?> message) async {
    final now = nowUs;
    if (now - _targetsAt >= _refreshUs) {
      _targetsAt = now;
      final targets = <String, InternetAddress>{_limited.address: _limited};
      final locals = <InternetAddress>[];
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        );
        for (final item in interfaces) {
          for (final address in item.addresses) {
            if (address.isLoopback || address.isLinkLocal) continue;
            locals.add(address);
            final target = _subnetBroadcast(address);
            targets[target.address] = target;
          }
        }
      } catch (_) {}
      _targets = targets.values.toList();
      if (_perInterface) await _bindSenders(locals);
    }
    for (final target in _targets) {
      send(message, target);
    }
    final data = _encode(message);
    for (final MapEntry(key: local, value: sender) in _senders.entries) {
      for (final target in [
        _limited,
        _subnetBroadcast(InternetAddress(local)),
      ]) {
        try {
          sender.send(data, target, Protocol.discoveryPort);
        } catch (_) {}
      }
    }
  }

  static InternetAddress _subnetBroadcast(InternetAddress address) {
    final raw = address.rawAddress;
    return InternetAddress.fromRawAddress(
      Uint8List.fromList([raw[0], raw[1], raw[2], 255]),
    );
  }

  /// 按当前的网卡地址增减发送套接字
  Future<void> _bindSenders(List<InternetAddress> locals) async {
    final keep = {for (final address in locals) address.address};
    _senders.removeWhere((local, sender) {
      if (keep.contains(local)) return false;
      sender.close();
      return true;
    });
    for (final address in locals) {
      if (_senders.containsKey(address.address)) continue;
      try {
        final sender = await RawDatagramSocket.bind(address, 0);
        if (_socket == null) {
          // 等待期间已关闭
          sender.close();
          return;
        }
        sender
          ..broadcastEnabled = true
          ..listen(
            (event) {
              if (event == RawSocketEvent.read) _receive(sender);
            },
            onError: (_) {},
          );
        _senders[address.address] = sender;
      } catch (_) {}
    }
  }
}

/// 音源：监听控制连接，广播自身并回应寻找与时钟校准
class SourceTransport {
  SourceTransport({
    required this.onConnected,
    required this.onMessage,
    required this.onDisconnected,
  });

  static const _beaconInterval = Duration(seconds: 1);

  final void Function(Connection) onConnected;
  final void Function(Connection, Message) onMessage;
  final void Function(Connection) onDisconnected;

  final Set<Connection> connections = {};
  late final _discovery = _Discovery(_onDatagram);
  ServerSocket? _server;
  bool _rebinding = false;
  Timer? _timer;
  bool _disposed = false;

  Future<void> start() async {
    await _bindServer();
    await _discovery.bind();
    _timer = Timer.periodic(_beaconInterval, (_) => _onTimer());
    _beacon();
  }

  Future<void> _bindServer() async {
    ServerSocket server;
    try {
      server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        Protocol.controlPort,
      );
    } on SocketException {
      server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    if (_disposed) {
      server.close();
      return;
    }
    _server = server;
    server.listen(
      _onSocket,
      onError: (_) {},
      onDone: () {
        if (identical(_server, server)) _server = null;
      },
    );
  }

  /// 网络变化后重新绑定发现端口并立即广播
  Future<void> refresh() async {
    if (_disposed) return;
    try {
      await _discovery.bind();
    } catch (_) {}
    _beacon();
  }

  void _onSocket(Socket socket) {
    if (_disposed) {
      socket.destroy();
      return;
    }
    final connection = Connection(
      socket,
      onMessage: _onMessage,
      onClosed: (connection) {
        if (connections.remove(connection) && !_disposed) {
          onDisconnected(connection);
        }
      },
    );
    connections.add(connection);
    onConnected(connection);
  }

  void _onMessage(Connection connection, Message message) {
    if (message['t'] == MessageType.ping) {
      connection.send({
        't': MessageType.pong,
        't0': message['t0'],
        't1': nowUs,
      });
      return;
    }
    onMessage(connection, message);
  }

  Map<String, Object?> get _beaconMessage => {
    'k': Datagram.beacon,
    'port': _server?.port,
  };

  void _beacon() {
    if (!_disposed) {
      _discovery.broadcast(_beaconMessage);
    }
  }

  void _onTimer() {
    if (_server == null && !_rebinding) {
      _rebinding = true;
      _bindServer().catchError((_) {}).whenComplete(() => _rebinding = false);
    }
    if (!_discovery.isOpen) refresh();
    final now = nowUs;
    for (final connection in connections.toList()) {
      if (now - connection.lastReceived > _silenceTimeoutUs) {
        connection.close();
      }
    }
    _beacon();
  }

  /// 回应寻找：发到发现端口，以及来源端口（对方未放行入站时经其发送套接字收到）
  void _onDatagram(Message message, InternetAddress from, int port) {
    if (message['k'] == Datagram.probe) {
      _discovery.send(_beaconMessage, from);
      if (port != Protocol.discoveryPort) {
        _discovery.send(_beaconMessage, from, port: port);
      }
    }
  }

  void broadcast(Map<String, Object?> message) {
    for (final connection in connections.toList()) {
      connection.send(message);
    }
  }

  /// 返回的 Future 在各连接已写入的消息发出后完成
  Future<void> dispose() {
    _disposed = true;
    _timer?.cancel();
    final closing = [
      for (final connection in connections.toList()) connection.close(),
    ];
    connections.clear();
    _discovery.close();
    _server?.close();
    _server = null;
    return Future.wait(closing);
  }
}

/// 控制台：寻找音源并保持一条控制连接，连接期间持续校准时钟
class ConsoleTransport {
  ConsoleTransport({
    required this.onConnected,
    required this.onMessage,
    required this.onDisconnected,
    required this.onSource,
    String? lastSource,
  }) : _lastSource = lastSource;

  static const _probeInterval = Duration(seconds: 2);
  static const _connectTimeout = Duration(seconds: 3);

  /// 连接后先密集采样，之后每秒一次
  static const _burstCount = 10;
  static const _burstInterval = Duration(milliseconds: 100);
  static const _pingInterval = Duration(seconds: 1);

  /// 唤醒后确认连接存活的等待时间
  static const _wakeCheckUs = 3000000;

  /// 拒绝协议版本不同的音源后，此时间内不再连接它
  static const _rejectUs = 30000000;

  final void Function() onConnected;
  final void Function(Message) onMessage;
  final void Function() onDisconnected;

  /// 连接成功的音源地址（host:port），保存后下次可直接连接
  final void Function(String) onSource;

  final clock = ClockSync();
  late final _discovery = _Discovery(_onDatagram);
  Timer? _probeTimer;
  Timer? _pingTimer;
  Connection? _connection;
  String? _lastSource;
  bool _connecting = false;
  bool _disposed = false;
  int _pingSeq = 0;
  int? _wakeAt;

  /// 被拒绝的音源地址及可再次连接的时刻
  final Map<String, int> _rejected = {};

  Connection? get connection => _connection;

  bool get isConnected => _connection != null;

  Future<void> start() async {
    await _discovery.bind();
    _probeTimer = Timer.periodic(_probeInterval, (_) => _check());
    _search();
  }

  /// 网络变化后重新绑定发现端口，并确认连接
  Future<void> refresh() async {
    if (_disposed) return;
    try {
      await _discovery.bind();
    } catch (_) {}
    wake();
  }

  /// 亮屏、回到前台、用户操作时：未连接则立即寻找音源，已连接则确认连接存活
  void wake() {
    if (_disposed) return;
    if (_connection == null) {
      _search();
      return;
    }
    _wakeAt = nowUs;
    _sendPing();
  }

  void _check() {
    if (!_discovery.isOpen) {
      refresh();
      return;
    }
    final connection = _connection;
    if (connection == null) {
      _search();
      return;
    }
    final now = nowUs;
    final wakeAt = _wakeAt;
    if (now - connection.lastReceived > _silenceTimeoutUs ||
        (wakeAt != null &&
            connection.lastReceived < wakeAt &&
            now - wakeAt > _wakeCheckUs)) {
      connection.close();
    } else if (wakeAt != null && connection.lastReceived >= wakeAt) {
      _wakeAt = null;
    }
  }

  void _search() {
    if (_connection != null || _connecting || _disposed) return;
    _discovery.broadcast(const {'k': Datagram.probe});
    if (_candidate case final candidate?) {
      _candidate = null;
      _connect(candidate.address, candidate.port);
      return;
    }
    // 广播被过滤时直接连接上次的音源
    if (_lastSource case final last?) {
      final index = last.lastIndexOf(':');
      if (index > 0) {
        final address = InternetAddress.tryParse(last.substring(0, index));
        final port = int.tryParse(last.substring(index + 1));
        if (address != null && port != null) {
          _connect(address, port);
        }
      }
    }
  }

  /// 连接期间收到的音源回应（如上次的地址已失效、音源换了地址），当前连接失败后优先尝试
  ({InternetAddress address, int port})? _candidate;

  void _onDatagram(Message message, InternetAddress from, int _) {
    if (message['k'] != Datagram.beacon || _connection != null) return;
    if (message['port'] case final int port) {
      if (_connecting) {
        _candidate = (address: from, port: port);
      } else {
        _connect(from, port);
      }
    }
  }

  /// 断开当前音源（协议版本不同），一段时间内不再连接它
  void reject() {
    final connection = _connection;
    if (connection == null) return;
    _rejected[connection.address] = nowUs + _rejectUs;
    connection.close();
  }

  Future<void> _connect(InternetAddress address, int port) async {
    if ((_rejected[address.address] ?? 0) > nowUs) return;
    _connecting = true;
    try {
      final socket = await Socket.connect(
        address,
        port,
        timeout: _connectTimeout,
      );
      if (_disposed || _connection != null) {
        socket.destroy();
        return;
      }
      clock.reset();
      _wakeAt = null;
      _connection = Connection(
        socket,
        onMessage: _onMessage,
        onClosed: _onClosed,
      );
      final source = '${address.address}:$port';
      if (source != _lastSource) {
        _lastSource = source;
        onSource(source);
      }
      _candidate = null;
      _pingSeq = 0;
      _schedulePing();
      onConnected();
    } catch (_) {
    } finally {
      _connecting = false;
    }
    if (_connection == null && !_disposed) {
      if (_candidate case final candidate?) {
        _candidate = null;
        if (candidate.address != address || candidate.port != port) {
          _connect(candidate.address, candidate.port);
        }
      }
    }
  }

  void _onMessage(Connection connection, Message message) {
    if (message['t'] == MessageType.pong) {
      final sentAt = message['t0'];
      final remoteAt = message['t1'];
      if (sentAt is int && remoteAt is int) {
        clock.add(sentAt: sentAt, remoteAt: remoteAt, receivedAt: nowUs);
      }
      return;
    }
    onMessage(message);
  }

  void _sendPing() {
    _connection?.send({'t': MessageType.ping, 't0': nowUs});
  }

  void _schedulePing() {
    _pingTimer?.cancel();
    _pingTimer = Timer(
      _pingSeq < _burstCount ? _burstInterval : _pingInterval,
      () {
        if (_connection == null) return;
        _pingSeq++;
        _sendPing();
        _schedulePing();
      },
    );
  }

  void _onClosed(Connection connection) {
    if (!identical(connection, _connection)) return;
    _connection = null;
    _wakeAt = null;
    _pingTimer?.cancel();
    clock.reset();
    if (!_disposed) {
      onDisconnected();
      _search();
    }
  }

  void send(Map<String, Object?> message) => _connection?.send(message);

  /// 返回的 Future 在已写入的消息发出后完成
  Future<void> dispose() {
    _disposed = true;
    _probeTimer?.cancel();
    _pingTimer?.cancel();
    final closing = _connection?.close() ?? Future<void>.value();
    _connection = null;
    _discovery.close();
    return closing;
  }
}
