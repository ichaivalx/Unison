import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:unison_native/unison_native.dart';

import '../settings.dart';
import 'calibration.dart';
import 'clock.dart';
import 'console.dart';
import 'models.dart';
import 'protocol.dart';
import 'transport.dart';

/// 一台接收端：设置保存在音源上，连接期间另有运行状态
class _Peer {
  _Peer(
    this.id, {
    this.name = '',
    this.platform = DevicePlatform.android,
    this.receive = false,
    this.baseOffsetUs = 0,
    this.volume = VolumeSetting.initial,
    BandGaps? gaps,
  }) : gaps = gaps ?? {};

  final String id;
  String name;
  DevicePlatform platform;
  bool receive;

  /// 按中高频对齐的偏移，不含按频段的平移
  int baseOffsetUs;
  VolumeSetting volume;
  BandGaps gaps;

  Connection? connection;
  int? receiverId;
  ReceiverStats? stats;
  double? actualVolume;

  /// 上次下发的设置及时刻；设备回报与之一致前定期重发
  String? applied;
  int appliedAt = 0;

  /// 设备回报的实际状态：是否在接收、生效的偏移、已设定的音量
  bool? reportedReceiving;
  int? reportedOffsetUs;
  double? reportedVolume;

  Map<String, Object?> toJson() => {
    'name': name,
    'platform': platform.name,
    'receive': receive,
    'baseOffsetUs': baseOffsetUs,
    'volume': volume.toJson(),
    'gaps': gapsToJson(gaps),
  };

  static _Peer fromJson(String id, Map json) => _Peer(
    id,
    name: json['name'] as String? ?? '',
    platform: DevicePlatform.values.asNameMap()[json['platform']] ?? DevicePlatform.android,
    receive: json['receive'] == true,
    baseOffsetUs: (json['baseOffsetUs'] as num?)?.toInt() ?? 0,
    volume: VolumeSetting.fromJson(json['volume']),
    gaps: gapsFromJson(json['gaps']),
  );
}

/// 校准前的设置，用于撤销
typedef _Snapshot = ({
  int localDelayUs,
  BandGaps localGaps,
  Map<String, ({int base, BandGaps gaps})> peers,
});

/// 音源设备上的控制服务：维护全部设置与状态，接受各控制台的连接与操作
class SourceService implements Console {
  SourceService._();

  static const _peersKey = 'source.peers';
  static const _enabledKey = 'source.enabled';
  static const _latencyKey = 'source.latencyUs';
  static const _localDelayKey = 'source.localDelayUs';
  static const _weightKey = 'band.weight';
  static const _localGapsKey = 'band.localGaps';
  static const _boostKey = 'calibration.boost';
  static const _boostLevelKey = 'calibration.boostLevel';

  static const _defaultLatencyUs = 50000;

  /// 设备回报与下发不一致时，距上次下发此时间后重发
  static const _retryUs = 2000000;

  /// 校准期间不能修改的时序设置
  static const _timing = {Command.latency, Command.localDelay, Command.offset, Command.bandWeight};

  static Future<SourceService> start() async {
    final service = SourceService._();
    await service._start();
    return service;
  }

  final _state = ValueNotifier<ConsoleState?>(null);
  final _connected = ValueNotifier(true);

  @override
  ValueListenable<ConsoleState?> get state => _state;

  @override
  ValueListenable<bool> get connected => _connected;

  @override
  String get selfId => LocalSettings.deviceId;

  @override
  bool get isSource => true;

  @override
  int localTimeOf(int sourceUs) => sourceUs;

  /// 从后台回到前台时保持常驻，使其他控制台随时能开启音源；退出后重新开启控制面
  @override
  void wake({required bool returned}) {
    if (!returned) return;
    UnisonNative.setKeepAlive(true).then((_) {
      // 音源只复用已建立的常驻服务
      if (_autoStart && _enabled) _startSource();
      _autoStart = false;
    }, onError: (_) {});
    if (_exited) {
      _exited = false;
      _transport = _newTransport();
      _transport.start().then((_) => _publish(), onError: (_) {});
    }
  }

  /// 通知上的“退出”：原生已停止音源与常驻；关闭控制面，下次启动 App 不再自动启动音源
  Future<void> _exit() async {
    if (_exited) return;
    _exited = true;
    _enabled = false;
    _prefs.setBool(_enabledKey, false);
    _links.clear();
    _boosted.clear();
    for (final peer in _peers.values) {
      peer
        ..connection = null
        ..stats = null;
    }
    _publish();
    await _transport.dispose();
  }

  final _prefs = LocalSettings.prefs;
  final Map<String, _Peer> _peers = {};
  late bool _enabled = _prefs.getBool(_enabledKey) ?? false;
  late int _latencyUs = _prefs.getInt(_latencyKey) ?? _defaultLatencyUs;
  late int _localDelayUs = _prefs.getInt(_localDelayKey) ?? 0;
  late double _weight = _prefs.getDouble(_weightKey) ?? 0;
  late BandGaps _localGaps = gapsFromJson(_decode(_prefs.getString(_localGapsKey)));
  late bool _boost = _prefs.getBool(_boostKey) ?? true;
  late double _boostLevel = _prefs.getDouble(_boostLevelKey) ?? 0.6;

  SourceStatus? _status;
  MediaState? _media;
  double? _volume;

  /// 本机设音量后此时间内的音量变化视为自身所致
  int _selfVolumeUntil = 0;

  /// 校准临时提高本机音量前的音量；未提高或期间已调整过时为 null
  double? _boostedFrom;

  /// 校准期间临时提高音量的接收端及其临时音量；期间调整过的不在其中
  final Map<String, double> _boosted = {};
  String? _error;
  CalibrationView _calibration = const CalibrationView();
  _Snapshot? _undo;
  bool _cancelled = false;

  late SourceTransport _transport = _newTransport();

  SourceTransport _newTransport() =>
      SourceTransport(onConnected: (_) {}, onMessage: _onMessage, onDisconnected: _onDisconnected);

  /// 用户从通知退出后控制面关闭，从后台回到前台时重新开启
  bool _exited = false;

  /// 已发来 hello 的连接及其设备
  final Map<Connection, _Peer> _links = {};

  Timer? _publishTimer;

  static Object? _decode(String? text) {
    if (text == null) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  Future<void> _start() async {
    if (_decode(_prefs.getString(_peersKey)) case final Map stored) {
      for (final MapEntry(:key, :value) in stored.entries) {
        if (key is String && value is Map) _peers[key] = _Peer.fromJson(key, value);
      }
    }
    _normalize();
    UnisonNative.sourceStatus.listen((status) {
      // 实际停止（如通知上停止音源、音源进程退出）：下次启动 App 不再自动启动
      if (_running && !status.running && _enabled) {
        _enabled = false;
        _prefs.setBool(_enabledKey, false);
      }
      _status = status;
      if (status.error != null) _error = status.error;
      _publish();
    }, onError: (_) {});
    UnisonNative.mediaState.listen((media) {
      _media = media;
      _publish();
    }, onError: (_) {});
    // 通知上的“退出”：原生已停止音源，下次启动 App 不再自动启动
    UnisonNative.exitRequests.listen((_) => _exit(), onError: (_) {});
    UnisonNative.volumeChanges.listen((volume) {
      _volume = volume;
      // 临时提高期间用户调整了本机音量：以调整为准，不再恢复
      if (nowUs >= _selfVolumeUntil) _boostedFrom = null;
      _publish();
    }, onError: (_) {});
    await _transport.start();
    _publish();
    UnisonNative.volume().then((volume) {
      _volume = volume;
      _publish();
    }, onError: (_) {});
    // 上次启用的音源等界面在前台、常驻就绪后再启动（见 wake）
    _autoStart = _enabled;
  }

  /// 启动 App 时待恢复的音源
  bool _autoStart = false;

  bool get _running => _status?.running ?? false;

  bool get _calibrating => _calibration.stage == CalibrationStage.running;

  /// 跟随音源的设备按此音量换算：临时提高期间为提高前的音量
  double? get _sourceVolume => _boostedFrom ?? _volume;

  Future<void> _setLocalVolume(double volume) {
    _volume = volume;
    _selfVolumeUntil = nowUs + 1000000;
    return _guard(() => UnisonNative.setVolume(volume));
  }

  int _effectiveOffset(_Peer peer) => peer.baseOffsetUs + bandShift(_weight, peer.gaps, _localGaps);

  void _savePeers() {
    _prefs.setString(_peersKey, jsonEncode({for (final peer in _peers.values) peer.id: peer.toJson()}));
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _error = e is UnsupportedError ? e.message : '$e';
      _publish();
    }
  }

  Future<void> _startSource() => _guard(() async {
    _error = null;
    await UnisonNative.startSource(latencyUs: _latencyUs, localDelayUs: _localDelayUs);
  });

  // ---- 控制连接 ----

  void _onMessage(Connection connection, Message message) {
    switch (message['t']) {
      case MessageType.hello:
        _onHello(connection, message);
      case MessageType.report:
        if (_links[connection] case final peer?) {
          peer
            ..stats = statsFromJson(message['stats'])
            ..actualVolume = (message['volume'] as num?)?.toDouble()
            ..reportedReceiving = message['receiving'] == true
            ..reportedOffsetUs = (message['offsetUs'] as num?)?.toInt()
            ..reportedVolume = (message['appliedVolume'] as num?)?.toDouble();
          _publish();
        }
      case MessageType.localVolume:
        if (_links[connection] case final peer?) {
          if (message['volume'] case final num volume) {
            _boosted.remove(peer.id);
            peer
              ..actualVolume = volume.toDouble()
              ..volume = peer.volume.withVolume(volume.toDouble(), _sourceVolume);
            _savePeers();
            _publish();
          }
        }
      case MessageType.command:
        if (_links.containsKey(connection)) {
          if (message['c'] case final String c) command(c, message);
        }
    }
  }

  void _onHello(Connection connection, Message message) {
    final id = message['id'];
    if (message['version'] != Protocol.version || id is! String || id == selfId) {
      connection
        ..send({'t': MessageType.incompatible, 'version': Protocol.version})
        ..close();
      return;
    }
    final peer = _peers.putIfAbsent(id, () => _Peer(id));
    // 同一设备的旧连接（未及时察觉断开）让位给新连接
    if (peer.connection case final old? when !identical(old, connection)) {
      _links.remove(old);
      old.close();
    }
    peer
      ..name = message['name'] as String? ?? peer.name
      ..platform = DevicePlatform.values.asNameMap()[message['platform']] ?? peer.platform
      ..receiverId = (message['receiverId'] as num?)?.toInt()
      ..connection = connection
      ..stats = null
      ..applied = null
      ..reportedReceiving = null
      ..reportedOffsetUs = null
      ..reportedVolume = null;
    _links[connection] = peer;
    _savePeers();
    _publish(immediate: true);
  }

  void _onDisconnected(Connection connection) {
    final peer = _links.remove(connection);
    if (peer == null || !identical(peer.connection, connection)) return;
    _boosted.remove(peer.id);
    peer
      ..connection = null
      ..stats = null;
    _publish();
  }

  // ---- 控制台操作 ----

  @override
  void command(String command, [Map<String, Object?> args = const {}]) {
    final id = args['id'];
    final peer = _peers[id];
    // 校准期间原生侧不接受时序修改，测量也按开始时的设置换算
    if (_calibrating && _timing.contains(command)) {
      _publish();
      return;
    }
    switch (command) {
      case Command.media:
        if (MediaCommand.values.asNameMap()[args['action']] case final action?) {
          _guard(() => UnisonNative.mediaCommand(action));
        }
      case Command.seek:
        if (args['positionUs'] case final num position) {
          _guard(() => UnisonNative.mediaSeek(position.toInt()));
        }
      case Command.source:
        _enabled = args['on'] == true;
        _prefs.setBool(_enabledKey, _enabled);
        if (_enabled) {
          _startSource();
        } else {
          _error = null;
          _guard(UnisonNative.stopSource);
        }
      case Command.latency:
        if (args['us'] case final num us) {
          _latencyUs = max(0, us.toInt());
          _prefs.setInt(_latencyKey, _latencyUs);
          if (_running) _guard(() => UnisonNative.setSourceLatencyUs(_latencyUs));
        }
      case Command.localDelay:
        if (args['us'] case final num us) _setLocalDelay(max(0, us.toInt()));
      case Command.offset:
        // 按增量调整：归一化会平移所有偏移，连续调节时绝对值的基准会变
        if (args['deltaUs'] case final num delta) {
          if (peer != null) {
            peer.baseOffsetUs += delta.toInt();
            _savePeers();
            _normalize();
          }
        }
      case Command.volume:
        if (args['value'] case final num value) {
          final volume = value.toDouble().clamp(0.0, 1.0).toDouble();
          if (id == selfId) {
            _boostedFrom = null;
            _setLocalVolume(volume);
          } else if (peer != null) {
            _boosted.remove(peer.id);
            peer.volume = peer.volume.withVolume(volume, _sourceVolume);
            _savePeers();
          }
        }
      case Command.volumeMode:
        if (VolumeMode.values.asNameMap()[args['mode']] case final mode?) {
          if (peer != null) {
            _boosted.remove(peer.id);
            peer.volume = peer.volume.switchTo(mode, peer.actualVolume, _sourceVolume);
            _savePeers();
          }
        }
      case Command.receive:
        if (peer != null) {
          peer.receive = args['on'] == true;
          _savePeers();
        }
      case Command.calibrate:
        _calibrate();
      case Command.calibrateCancel:
        if (_calibration.stage == CalibrationStage.running) {
          _cancelled = true;
          _guard(UnisonNative.cancelCalibration);
        }
      case Command.calibrateUndo:
        _undoCalibration();
      case Command.calibrateClose:
        if (_calibration.stage != CalibrationStage.running) {
          _calibration = const CalibrationView();
          _undo = null;
        }
      case Command.boost:
        if (args['on'] case final bool on) {
          _boost = on;
          _prefs.setBool(_boostKey, on);
        }
        if (args['level'] case final num level) {
          _boostLevel = level.toDouble().clamp(0.0, 1.0).toDouble();
          _prefs.setDouble(_boostLevelKey, _boostLevel);
        }
      case Command.bandWeight:
        if (args['weight'] case final num weight) {
          _weight = weight.toDouble().clamp(0.0, 1.0).toDouble();
          _prefs.setDouble(_weightKey, _weight);
          _normalize();
        }
    }
    _publish();
  }

  /// 使所有已知设备（含离线的）的生效偏移不小于 0；[minimize] 时并使本机延迟尽量小
  void _normalize({bool minimize = true}) {
    final shift = normalizationShift(_localDelayUs, [for (final peer in _peers.values) _effectiveOffset(peer)]);
    if (shift == 0 || (!minimize && shift < 0)) return;
    for (final peer in _peers.values) {
      peer.baseOffsetUs += shift;
    }
    _savePeers();
    _setLocalDelay(_localDelayUs + shift);
  }

  void _setLocalDelay(int us) {
    _localDelayUs = us;
    _prefs.setInt(_localDelayKey, us);
    if (_running) _guard(() => UnisonNative.setLocalDelayUs(us));
  }

  // ---- 校准 ----

  void _failCalibration(String message) {
    _calibration = CalibrationView(stage: CalibrationStage.failed, message: message);
    _publish();
  }

  Future<void> _calibrate() async {
    if (_calibration.stage == CalibrationStage.running) return;
    if (!_running) {
      _failCalibration('音源未启动');
      return;
    }
    final receiving = _status?.receiverIds.toSet() ?? const {};
    final peers = {
      for (final peer in _peers.values)
        if (peer.receiverId case final rid? when peer.connection != null && receiving.contains(rid))
          rid: peer,
    };
    if (peers.isEmpty) {
      _failCalibration('没有正在接收的设备');
      return;
    }
    _cancelled = false;
    _calibration = const CalibrationView(stage: CalibrationStage.running, description: '准备中');
    // 测量在此时的设置下进行；期间时序设置冻结
    final effective = {for (final peer in peers.values) peer.id: _effectiveOffset(peer)};
    final undo = (
      localDelayUs: _localDelayUs,
      localGaps: _localGaps,
      peers: {for (final peer in _peers.values) peer.id: (base: peer.baseOffsetUs, gaps: peer.gaps)},
    );
    _publish(immediate: true);
    try {
      if (_boost) await _raiseVolumes(peers.values);
      if (_cancelled) throw const CalibrationFailure('已取消');
      final result = await UnisonNative.calibrate(
        receiverIds: peers.keys.toList(),
        bands: CalibrationBand.values,
        onProgress: (progress) {
          _calibration = CalibrationView(
            stage: CalibrationStage.running,
            step: progress.step,
            totalSteps: progress.totalSteps,
            description: progress.description,
          );
          _publish();
        },
      );
      final outcome = solveCalibration(
        effective: effective,
        local: result.local,
        receivers: {
          for (final MapEntry(key: rid, value: peer) in peers.entries)
            peer.id: result.receivers[rid] ?? const [],
        },
      );
      _undo = undo;
      _localGaps = outcome.localGaps;
      for (final peer in _peers.values) {
        peer.baseOffsetUs = outcome.baseOffsets[peer.id] ?? peer.baseOffsetUs;
        if (outcome.gaps[peer.id] case final gaps?) peer.gaps = gaps;
      }
      _saveCalibration();
      _normalize();
      _calibration = CalibrationView(
        stage: CalibrationStage.done,
        canUndo: true,
        rows: [
          CalibrationRow(
            name: LocalSettings.deviceName,
            result: '本机延迟 ${formatMs(_localDelayUs)}',
            detail: _localGapsNote(),
          ),
          for (final peer in peers.values)
            outcome.missing.contains(peer.id)
                ? CalibrationRow(name: peer.name, result: '未测到测试音')
                : CalibrationRow(
                    name: peer.name,
                    result: formatOffset(_effectiveOffset(peer)),
                    detail: bandNote(peer.gaps, _localGaps),
                  ),
        ],
      );
      _publish();
    } on CalibrationFailure catch (e) {
      _failCalibration(e.message);
    } catch (e) {
      _failCalibration(_cancelled ? '已取消' : (e is UnsupportedError ? '${e.message}' : '$e'));
    } finally {
      _restoreVolumes();
    }
  }

  /// 把本机与参与校准的设备中音量低于设定值的临时提高到该值
  Future<void> _raiseVolumes(Iterable<_Peer> peers) async {
    final level = _boostLevel;
    for (final peer in peers) {
      final actual = peer.actualVolume;
      if (actual == null || actual < level) _boosted[peer.id] = level;
    }
    if (_volume case final local? when local < level) {
      _boostedFrom = local;
      await _setLocalVolume(level);
    }
    if (_boosted.isEmpty) return;
    _publish(immediate: true);
    // 等各设备设好音量再播放测试音
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  /// 恢复临时提高的音量；期间调整过的设备已不在其中
  void _restoreVolumes() {
    _boosted.clear();
    if (_boostedFrom case final volume?) {
      _boostedFrom = null;
      _setLocalVolume(volume);
    }
    _publish();
  }

  String _localGapsNote() {
    if (_localGaps.isEmpty) return '未测到低频';
    return [
      for (final MapEntry(key: band, value: gap) in _localGaps.entries)
        '${bandLabel(band)}${gap < 0 ? '早' : '晚'} ${formatMs(gap.abs())}',
    ].join('，');
  }

  void _saveCalibration() {
    _prefs.setString(_localGapsKey, jsonEncode(gapsToJson(_localGaps)));
    _savePeers();
  }

  void _undoCalibration() {
    final undo = _undo;
    if (undo == null || _calibration.stage == CalibrationStage.running) return;
    _undo = null;
    _localGaps = undo.localGaps;
    for (final MapEntry(key: id, value: saved) in undo.peers.entries) {
      if (_peers[id] case final peer?) {
        peer
          ..baseOffsetUs = saved.base
          ..gaps = saved.gaps;
      }
    }
    _setLocalDelay(undo.localDelayUs);
    _saveCalibration();
    // 快照本身合法，只在其后调过对齐频段而出现负偏移时修正
    _normalize(minimize: false);
    _calibration = const CalibrationView(message: '已撤销本次校准');
  }

  // ---- 状态 ----

  void _publish({bool immediate = false}) {
    if (immediate) {
      _publishTimer?.cancel();
      _publishTimer = null;
      _doPublish();
      return;
    }
    _publishTimer ??= Timer(const Duration(milliseconds: 50), () {
      _publishTimer = null;
      _doPublish();
    });
  }

  void _doPublish() {
    final status = _status;
    final receiving = status?.receiverIds.toSet() ?? const {};
    final others = _peers.values.toList()
      ..sort((a, b) {
        if ((a.connection == null) != (b.connection == null)) return a.connection == null ? 1 : -1;
        return a.name.compareTo(b.name);
      });
    final available = _localGaps.isNotEmpty || _peers.values.any((p) => p.gaps.isNotEmpty);
    final state = ConsoleState(
      sourceId: selfId,
      source: SourceView(
        running: status?.running ?? false,
        latencyUs: _latencyUs,
        localDelayUs: _localDelayUs,
        error: _error,
        sessions: [for (final s in status?.sessions ?? const <CapturedSession>[]) s.packageName ?? 'uid ${s.uid}'],
      ),
      media: _media == null ? null : MediaView.of(_media!),
      devices: [
        DeviceView(
          id: selfId,
          name: LocalSettings.deviceName,
          platform: DevicePlatform.android,
          isSource: true,
          online: true,
          receive: false,
          receiving: false,
          offsetUs: 0,
          volume: VolumeSetting.initial,
          actualVolume: _volume,
          stats: null,
        ),
        for (final peer in others)
          DeviceView(
            id: peer.id,
            name: peer.name,
            platform: peer.platform,
            isSource: false,
            online: peer.connection != null,
            receive: peer.receive,
            receiving: peer.connection != null && receiving.contains(peer.receiverId),
            offsetUs: _effectiveOffset(peer),
            volume: peer.volume,
            actualVolume: peer.actualVolume,
            stats: peer.stats,
          ),
      ],
      calibration: _calibration,
      boost: _boost ? _boostLevel : null,
      band: BandView(
        weight: _weight,
        available: available,
        notes: [
          if (available) '本机：${_localGapsNote()}',
          for (final peer in others)
            if (peer.gaps.isNotEmpty) '${peer.name}：${bandNote(peer.gaps, _localGaps)}',
        ],
      ),
      sentAtUs: nowUs,
    );
    _state.value = state;
    final message = {'t': MessageType.state, 's': state.toJson()};
    for (final connection in _links.keys) {
      connection.send(message);
    }
    final now = nowUs;
    for (final peer in _links.values) {
      final receive = peer.receive;
      final offset = _effectiveOffset(peer);
      final volume = _boosted[peer.id] ?? peer.volume.target(_sourceVolume);
      final apply = jsonEncode({'receive': receive, 'offsetUs': offset, 'volume': volume});
      // 以设备回报的实际状态为准：未生效的定期重发
      final synced =
          peer.reportedReceiving == receive &&
          (!receive || peer.reportedOffsetUs == offset) &&
          (volume == null || peer.reportedVolume == volume);
      if (apply == peer.applied && (synced || now - peer.appliedAt < _retryUs)) continue;
      peer
        ..applied = apply
        ..appliedAt = now;
      peer.connection?.send({'t': MessageType.apply, ...jsonDecode(apply) as Map<String, dynamic>});
    }
  }
}
