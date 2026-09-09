import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Continuity measurement for a solid tone, not arbitrary music or speech.
class ToneAnalysis {
  ToneAnalysis(
    this.rate,
    this.channels,
    this.frames,
    this.first,
    this.last,
    this.gaps,
    this.rms,
  );
  final int rate, channels, frames;
  final int? first, last;
  final List<(int, int)> gaps;
  final List<double> rms;
}

ToneAnalysis analyzeTone(
  Uint8List bytes, {
  double silenceDb = -45,
  double minimumGapMs = 5,
}) {
  if (!silenceDb.isFinite || !minimumGapMs.isFinite || minimumGapMs <= 0) {
    throw const FormatException('invalid silence threshold or minimum gap');
  }
  final data = ByteData.sublistView(bytes);
  bool tag(int at, String value) =>
      at + 4 <= bytes.length &&
      String.fromCharCodes(bytes.sublist(at, at + 4)) == value;
  if (bytes.length < 12 || !tag(0, 'RIFF') || !tag(8, 'WAVE')) {
    throw const FormatException('expected RIFF/WAVE');
  }
  final limit = data.getUint32(4, Endian.little) + 8;
  if (limit > bytes.length || limit < 12) {
    throw const FormatException('truncated RIFF file');
  }
  int? channels, rate, alignment, pcmStart, pcmLength;
  for (var cursor = 12; cursor + 8 <= limit;) {
    final size = data.getUint32(cursor + 4, Endian.little);
    final start = cursor + 8;
    if (start + size > limit)
      throw const FormatException('truncated WAV chunk');
    if (tag(cursor, 'fmt ')) {
      if (size < 16 ||
          data.getUint16(start, Endian.little) != 1 ||
          data.getUint16(start + 14, Endian.little) != 16) {
        throw const FormatException('expected signed 16-bit PCM');
      }
      channels = data.getUint16(start + 2, Endian.little);
      rate = data.getUint32(start + 4, Endian.little);
      alignment = data.getUint16(start + 12, Endian.little);
    } else if (tag(cursor, 'data')) {
      pcmStart = start;
      pcmLength = size;
    }
    cursor = start + size + (size & 1);
  }
  if (channels == null ||
      channels < 1 ||
      rate == null ||
      rate < 1 ||
      alignment != channels * 2 ||
      pcmStart == null ||
      pcmLength == null ||
      pcmLength % (channels * 2) != 0) {
    throw const FormatException('malformed PCM format/frame count');
  }
  final frames = pcmLength ~/ (channels * 2);
  final threshold = (32767 * math.pow(10, silenceDb / 20)).round();
  final minimum = math.max(1, (rate * minimumGapMs / 1000).round());
  int? first, last, runStart;
  final gaps = <(int, int)>[];
  for (var frame = 0; frame < frames; frame++) {
    var amplitude = 0;
    for (var channel = 0; channel < channels; channel++) {
      amplitude = math.max(
        amplitude,
        data
            .getInt16(
              pcmStart + (frame * channels + channel) * 2,
              Endian.little,
            )
            .abs(),
      );
    }
    if (amplitude > threshold) {
      first ??= frame;
      last = frame;
      if (runStart != null && frame - runStart >= minimum) {
        gaps.add((runStart, frame));
      }
      runStart = null;
    } else if (first != null) {
      runStart ??= frame;
    }
  }
  final rms = <double>[];
  if (first != null && last != null) {
    final window = math.max(1, (rate * .050).round());
    for (var cursor = first; cursor + window <= last + 1; cursor += window) {
      var sum = 0.0;
      for (
        var sample = cursor * channels;
        sample < (cursor + window) * channels;
        sample++
      ) {
        final value = data.getInt16(pcmStart + sample * 2, Endian.little);
        sum += value * value;
      }
      final value = math.sqrt(sum / (window * channels)) / 32768;
      rms.add(20 * math.log(math.max(value, 1e-15)) / math.ln10);
    }
  }
  return ToneAnalysis(rate, channels, frames, first, last, gaps, rms);
}

const analyzeToneHelp =
    '''toolbox dev diagnostics analyze-tone WAV [--silence-db -45] [--minimum-gap-ms 5]
Measure continuity of a solid signed 16-bit PCM WAV tone, not music or speech.
Leading/trailing silence is excluded. A sibling .meta file may supply capture_started_at.
Exit codes: 0 continuous tone, 1 no active tone, 2 dropouts, 64 invalid input.
''';

int runToneAnalysis(
  List<String> arguments, {
  void Function(String)? output,
  void Function(String)? errorOutput,
}) {
  final write = output ?? stdout.writeln;
  final writeError = errorOutput ?? stderr.writeln;
  try {
    String? path;
    var silenceDb = -45.0, minimumGapMs = 5.0;
    for (var i = 0; i < arguments.length; i++) {
      final arg = arguments[i];
      if (arg == '--help' || arg == '-h') {
        write(analyzeToneHelp);
        return 0;
      }
      if (arg == '--silence-db' || arg == '--minimum-gap-ms') {
        if (++i == arguments.length)
          throw FormatException('missing value for $arg');
        final value = double.parse(arguments[i]);
        if (arg == '--silence-db') {
          silenceDb = value;
        } else {
          minimumGapMs = value;
        }
      } else if (arg.startsWith('-') || path != null) {
        throw FormatException('unexpected argument: $arg');
      } else {
        path = arg;
      }
    }
    if (path == null)
      throw const FormatException('expected WAV path (see --help)');
    final result = analyzeTone(
      File(path).readAsBytesSync(),
      silenceDb: silenceDb,
      minimumGapMs: minimumGapMs,
    );
    DateTime? started;
    final dot = path.lastIndexOf('.');
    final metadata = File('${dot < 0 ? path : path.substring(0, dot)}.meta');
    if (metadata.existsSync()) {
      for (final line in metadata.readAsLinesSync()) {
        if (line.startsWith('capture_started_at=')) {
          started = DateTime.parse(
            line.substring('capture_started_at='.length).replaceAll(',', '.'),
          );
        }
      }
    }
    String offset(int frame) {
      final seconds = frame / result.rate;
      final relative = '${seconds.toStringAsFixed(6)}s';
      return started == null
          ? relative
          : '$relative (${started.add(Duration(microseconds: (seconds * 1e6).round())).toIso8601String()})';
    }

    write('file=$path');
    write(
      'duration=${(result.frames / result.rate).toStringAsFixed(6)}s rate=${result.rate} channels=${result.channels} silence_threshold=${silenceDb.toStringAsFixed(2)}dBFS',
    );
    if (result.first == null) {
      write('active_tone=none');
      return 1;
    }
    write('tone_start=${offset(result.first!)}');
    write('tone_end=${offset(result.last! + 1)}');
    write(
      'tone_span=${((result.last! + 1 - result.first!) / result.rate).toStringAsFixed(6)}s',
    );
    final label = minimumGapMs == minimumGapMs.roundToDouble()
        ? minimumGapMs.toInt().toString()
        : minimumGapMs.toString();
    write('dropouts_at_least_${label}ms=${result.gaps.length}');
    for (final (start, end) in result.gaps) {
      write(
        'dropout start=${offset(start)} duration=${((end - start) * 1000 / result.rate).toStringAsFixed(3)}ms',
      );
    }
    if (result.rms.isNotEmpty) {
      final rms = result.rms..sort();
      final middle = rms.length ~/ 2;
      final median = rms.length.isOdd
          ? rms[middle]
          : (rms[middle - 1] + rms[middle]) / 2;
      write(
        'rms_50ms_db=min:${rms.first.toStringAsFixed(3)},median:${median.toStringAsFixed(3)},max:${rms.last.toStringAsFixed(3)}',
      );
    }
    return result.gaps.isEmpty ? 0 : 2;
  } on Object catch (error) {
    writeError('analyze-tone: $error');
    return 64;
  }
}
