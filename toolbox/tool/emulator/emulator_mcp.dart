// An MCP server for the running emulator: press its buttons, turn its
// wheel, read its screen, ask it questions.
//
//   dart toolbox/tool/emulator/emulator_mcp.dart
//
// Speaks MCP over stdio - one JSON-RPC message per line - and talks to the
// emulator over the Dart VM service the `flutter run` printed. It finds
// that service itself, so nothing has to be passed in and nothing goes
// stale when the emulator is relaunched: every call looks the observatory
// up again.
//
// Why this exists. The emulator draws a wheel and five buttons, and until
// now the only way to press one from outside the process was to send a key
// event to its window and hope the compositor had put the focus where you
// meant. That races the window manager, needs the window fronted, and a
// press that lands on the wrong window does nothing at all - silently,
// which is the worst way for a tool to fail. Here the press goes straight
// to the hardware the drawn wheel presses, by name.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Where the emulator writes the line `flutter run` printed, if the
/// harness that launched it saved one. Checked before the search.
const _urlEnv = 'TEMPO_EMULATOR_VM_URL';

/// The library the emulator's hardware handle lives in.
const _hardware = 'tempo_toolbox/emulator/src/hardware.dart';

/// How long a held button is held: past every threshold the machine
/// counts, with room to spare for a frame or two of slack.
const _holdFor = Duration(milliseconds: 1600);

Future<void> main(List<String> args) async {
  final server = _Server();
  await server.serve();
}

// ---------------------------------------------------------------------------
// MCP, over stdio
// ---------------------------------------------------------------------------

class _Server {
  static const _tools = [
    {
      'name': 'press',
      'description':
          'Press a button on the emulator: select, menu, next, previous, '
          'playPause, volumeUp, volumeDown, power. Set hold to give the '
          "button its long word instead - menu held is the dock, power "
          'held is the power dialog.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'button': {'type': 'string'},
          'hold': {'type': 'boolean'},
        },
        'required': ['button'],
      },
    },
    {
      'name': 'jog',
      'description':
          'Turn the wheel one detent at a time, a frame apart, the way a '
          'thumb does: negative is up a list, positive is down. Use this '
          'to walk, and spin to leap.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'detents': {'type': 'integer'},
        },
        'required': ['detents'],
      },
    },
    {
      'name': 'spin',
      'description':
          'The whole turn at once, as a single jog: a list moves exactly '
          'that many rows, which is what makes counted navigation exact.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'detents': {'type': 'integer'},
        },
        'required': ['detents'],
      },
    },
    {
      'name': 'screen',
      'description':
          'What is on the panel, as text: every string the render tree '
          'draws, in the order it draws them. Cheaper and more exact than '
          'a screenshot for asking what a screen says.',
      'inputSchema': {'type': 'object', 'properties': {}},
    },
    {
      'name': 'eval',
      'description':
          'Evaluate a Dart expression inside the running emulator, in the '
          'scope of a library whose path contains the given substring. '
          "For reading and moving the player's own notifiers.",
      'inputSchema': {
        'type': 'object',
        'properties': {
          'library': {'type': 'string'},
          'expression': {'type': 'string'},
        },
        'required': ['library', 'expression'],
      },
    },
    {
      'name': 'status',
      'description':
          'Whether an emulator is running and reachable, and where its VM '
          'service is.',
      'inputSchema': {'type': 'object', 'properties': {}},
    },
  ];

  Future<void> serve() async {
    final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      Map<String, dynamic> request;
      try {
        request = jsonDecode(line) as Map<String, dynamic>;
      } on Object {
        continue;
      }
      final reply = await _handle(request);
      // A notification - no id - wants no answer.
      if (reply != null) stdout.writeln(jsonEncode(reply));
    }
  }

  Future<Map<String, dynamic>?> _handle(Map<String, dynamic> request) async {
    final id = request['id'];
    final method = request['method'] as String?;
    if (id == null) return null;

    Map<String, dynamic> ok(Object? result) => {
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };

    switch (method) {
      case 'initialize':
        return ok({
          'protocolVersion': '2024-11-05',
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': 'tempo-emulator', 'version': '0.1.0'},
        });
      case 'tools/list':
        return ok({'tools': _tools});
      case 'tools/call':
        final params = (request['params'] as Map).cast<String, dynamic>();
        final name = params['name'] as String;
        final arguments =
            (params['arguments'] as Map?)?.cast<String, dynamic>() ?? {};
        try {
          return ok({
            'content': [
              {'type': 'text', 'text': await _call(name, arguments)},
            ],
          });
        } on Object catch (error) {
          // A tool that failed says so in its result rather than as a
          // protocol error: the caller wants to read what went wrong.
          return ok({
            'content': [
              {'type': 'text', 'text': '$error'},
            ],
            'isError': true,
          });
        }
      case 'ping':
        return ok(<String, Object?>{});
      default:
        return {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'no method "$method"'},
        };
    }
  }

  Future<String> _call(String name, Map<String, dynamic> arguments) async {
    switch (name) {
      case 'status':
        final url = await _findService();
        if (url == null) return 'no emulator running';
        final vm = await _Vm.connect(url);
        try {
          final running = await vm.eval(
            _hardware,
            'EmulatorHardware.running.toString()',
          );
          return 'emulator at $url, hardware ${running == 'true' ? 'up' : 'not up yet'}';
        } finally {
          await vm.close();
        }
      case 'press':
        final button = arguments['button'] as String;
        final hold = arguments['hold'] == true;
        return _withVm((vm) async {
          final known = await vm.eval(
            _hardware,
            "EmulatorHardware.knows('$button').toString()",
          );
          if (known != 'true') throw 'no button named "$button"';
          if (!hold) {
            await vm.eval(
              _hardware,
              "EmulatorHardware.pressNamed('$button').toString()",
            );
            return 'pressed $button';
          }
          // A held button is genuinely held: the machine counts the long
          // word from the key's own edges, and a wait that happened in
          // the app's isolate would be a wait the VM service was blocked
          // on. So the waiting is done here, between two calls.
          await vm.eval(
            _hardware,
            "EmulatorHardware.down('$button').toString()",
          );
          await Future<void>.delayed(_holdFor);
          await vm.eval(_hardware, "EmulatorHardware.up('$button').toString()");
          return 'held $button';
        });
      case 'jog':
        final detents = arguments['detents'] as int;
        final one = detents.isNegative ? -1 : 1;
        return _withVm((vm) async {
          for (var i = 0; i < detents.abs(); i++) {
            await vm.eval(_hardware, 'EmulatorHardware.jog($one).toString()');
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
          return 'jogged $detents';
        });
      case 'spin':
        final detents = arguments['detents'] as int;
        return _withVm((vm) async {
          await vm.eval(_hardware, 'EmulatorHardware.jog($detents).toString()');
          return 'spun $detents';
        });
      case 'screen':
        return _withVm((vm) async {
          final text = await vm.extension('screen');
          return text;
        });
      case 'eval':
        return _withVm(
          (vm) => vm.eval(
            arguments['library'] as String,
            arguments['expression'] as String,
          ),
        );
      default:
        throw 'no tool named "$name"';
    }
  }

  Future<String> _withVm(Future<String> Function(_Vm vm) body) async {
    final url = await _findService();
    if (url == null) throw 'no emulator running';
    final vm = await _Vm.connect(url);
    try {
      return await body(vm);
    } finally {
      await vm.close();
    }
  }
}

/// Every string the panel is actually drawing, in paint order.
///
/// Walks the element tree for Text and its kin rather than asking a
/// screenshot, so what comes back is what the screen *says* - which is
/// what a caller checking a screen almost always wants.
///
/// Offstage subtrees are skipped, and that matters more here than it
/// looks: the dock keeps every app in the tree at all times, so a walk
/// that took them all would answer with every app's contents at once and
/// never change no matter what you pressed.
///
/// One line, with no newline in it anywhere: the VM service compiles an
/// expression as a single line and answers a multi-line one with a parse
/// error about an unmatched brace.
// ---------------------------------------------------------------------------
// The VM service
// ---------------------------------------------------------------------------

/// Find the running emulator's VM service.
///
/// The environment first, where a harness can say exactly which one it
/// means; failing that, the observatory ports the machine has open. A
/// developer with two Flutter processes up gets the first that answers to
/// the emulator's own library, not a guess.
Future<String?> _findService() async {
  final told = Platform.environment[_urlEnv];
  if (told != null && told.isNotEmpty) return _normalise(told);

  for (final url in await _observatories()) {
    try {
      final vm = await _Vm.connect(url);
      try {
        final running = await vm.eval(
          _hardware,
          'EmulatorHardware.running.toString()',
        );
        if (running == 'true') return url;
      } finally {
        await vm.close();
      }
    } on Object {
      continue;
    }
  }
  return null;
}

/// Every observatory URL this machine has written down, newest first.
///
/// The VM service's address carries an auth token in its path, so it
/// cannot be guessed from a port: it has to be read from wherever the
/// process that started the emulator wrote it. Two places are looked at -
/// what `flutter run --vmservice-out-file` wrote, and the run's own log -
/// and a URL found in either is tried against the emulator's own library,
/// so another Flutter process on the same machine is not mistaken for it.
Future<List<String>> _observatories() async {
  final found = <String>{};
  for (final path in [
    Platform.environment[_outFileEnv],
    Platform.environment[_logEnv],
    _defaultOutFile,
    _defaultLog,
  ].whereType<String>()) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final text = file.readAsStringSync().trim();
    if (text.startsWith('http') || text.startsWith('ws')) {
      // --vmservice-out-file writes the one URL and nothing else - as a
      // websocket address, `ws://host:port/token/ws`, where the log's
      // line is the http one. Either shape comes back the same here.
      found.add(_normalise(text));
      continue;
    }
    for (final match in RegExp(
      r'http://127\.0\.0\.1:\d+/[A-Za-z0-9_=-]+/',
    ).allMatches(text)) {
      found.add(match.group(0)!);
    }
  }
  return found.toList().reversed.toList();
}

/// One address, whichever shape it was written in: the http base the VM
/// service answers on, with its token and a trailing slash.
String _normalise(String url) {
  var found = url.trim();
  if (found.startsWith('ws')) found = found.replaceFirst('ws', 'http');
  if (found.endsWith('/ws')) {
    found = found.substring(0, found.length - '/ws'.length);
  }
  return found.endsWith('/') ? found : '$found/';
}

/// Where `flutter run --vmservice-out-file` was told to write, and where
/// the run's log was kept.
const _outFileEnv = 'TEMPO_EMULATOR_VM_FILE';
const _logEnv = 'TEMPO_EMULATOR_LOG';

String get _home => Platform.environment['HOME'] ?? '.';

String get _defaultOutFile => '$_home/.cache/tempo/emulator-vm.url';

String get _defaultLog => '$_home/.cache/tempo/emulator.log';

/// One connection to the VM service, and the two calls this needs.
class _Vm {
  _Vm._(this._socket) {
    // One listener, over the one map the calls register in. Splitting
    // those - a local map for the handshake, the field for everything
    // after - is a connection that answers the first call and then hangs
    // forever, which is exactly how this was written the first time.
    _socket.listen((data) {
      final message = jsonDecode(data as String) as Map<String, dynamic>;
      _pending.remove('${message['id']}')?.complete(message);
    });
  }

  final WebSocket _socket;
  final _pending = <String, Completer<Map<String, dynamic>>>{};

  var _id = 0;
  late final String _isolateId;
  late final List<Map<String, dynamic>> _libraries;

  static Future<_Vm> connect(String url) async {
    final ws =
        '${url.replaceFirst('http://', 'ws://').replaceFirst(RegExp(r'/$'), '')}'
        '/ws';
    final vm = _Vm._(await WebSocket.connect(ws));
    await vm._handshake();
    return vm;
  }

  /// Which isolate, and what is in it: asked once, since a library's id
  /// is good for the life of the connection.
  Future<void> _handshake() async {
    final vm = await _call('getVM');
    _isolateId =
        ((vm['result']['isolates'] as List).first as Map)['id'] as String;
    final isolate = await _call('getIsolate', {'isolateId': _isolateId});
    _libraries = (isolate['result']['libraries'] as List)
        .cast<Map>()
        .map((library) => library.cast<String, dynamic>())
        .toList();
  }

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    final key = '${_id++}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[key] = completer;
    final message = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': key,
      'method': method,
    };
    if (params != null) message['params'] = params;
    _socket.add(jsonEncode(message));
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _pending.remove(key);
        throw 'VM service timed out calling $method';
      },
    );
  }

  String _library(String substring) {
    for (final library in _libraries) {
      if ('${library['uri']}'.contains(substring)) {
        return library['id'] as String;
      }
    }
    throw 'no library matching "$substring"';
  }

  /// Evaluate [expression] in [librarySubstring]'s scope, as a string.
  Future<String> extension(String action, [String argument = '']) async {
    final reply = await _call('ext.tempo.emulator', {
      'isolateId': _isolateId,
      'action': action,
      'argument': argument,
    });
    if (reply['error'] != null) throw '${reply['error']}';
    return '${reply['result']['value']}';
  }

  Future<String> eval(String librarySubstring, String expression) async {
    if (librarySubstring == _hardware) {
      if (expression == 'EmulatorHardware.running.toString()')
        return extension('status');
      final match = RegExp(
        r"^EmulatorHardware\.(\w+)\((.*?)\)\.toString\(\)$",
      ).firstMatch(expression);
      if (match != null) {
        var argument = match.group(2)!;
        if (argument.startsWith("'") && argument.endsWith("'"))
          argument = argument.substring(1, argument.length - 1);
        return extension(match.group(1)!, argument);
      }
    }

    final reply = await _call('evaluate', {
      'isolateId': _isolateId,
      'targetId': _library(librarySubstring),
      'expression': expression,
    });
    final error = reply['error'];
    if (error != null) {
      throw const JsonEncoder.withIndent('  ').convert(error);
    }
    final result = (reply['result'] as Map).cast<String, dynamic>();
    if (result['kind'] == 'Error' || result['type'] == '@Error') {
      throw '${result['message'] ?? result}';
    }
    return '${result['valueAsString'] ?? result['kind'] ?? result}';
  }

  Future<void> close() => _socket.close();
}
