// Shows how Scene.maxGpuFramesInFlight behaves on a real display, which the
// smoke harness can't: it pumps frames itself. Stacks translucent layers to raise
// the GPU load step by step, compares limits at each step, and logs frames shown
// and how long each frame took from tick to GPU completion.
//
//   cd examples/smoke_render
//   flutter run --profile -d macos --enable-flutter-gpu -t lib/pace_probe.dart
//   flutter run --profile --flavor vulkan -d <phone> --enable-flutter-gpu \
//     -t lib/pace_probe.dart
//
// Run a phone at 60 Hz: other refresh rates change where the steps fall.
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/render/frame_transients.dart'
    show rendererSubmissions;
import 'package:vector_math/vector_math.dart' as vm;

const _steps = [0, 1, 2, 3, 4, 6, 8, 12, 16, 20, 24, 32, 40];
const _limits = [2, 1];
const _secondsPerLimit = 4;

void main() =>
    runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: Probe()));

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _ProbeState();
}

class _Frame {
  _Frame(this.lastId, this.tick, this.lastSubmit);
  final int lastId;
  final int tick;
  final int lastSubmit;
}

class _ProbeState extends State<Probe> {
  Scene? _scene;
  final _camera = PerspectiveCamera(
    position: vm.Vector3(0, 0, 3),
    target: vm.Vector3(0, 0, 0),
  );
  final _clock = Stopwatch()..start();
  final _layers = <Node>[];
  final _open = Queue<_Frame>();
  final _doneAt = <int, int>{};
  final _times = <int>[];
  int _ticks = 0, _paced = 0, _step = 0, _limit = -1;
  int _tickAt = 0, _lastSubmit = 0, _closedId = 0, _doneThrough = 0;
  double _since = 0, _settle = 1;

  @override
  void initState() {
    super.initState();
    Scene.preload().then((_) {
      final scene = Scene();
      final geometry = CuboidGeometry(vm.Vector3(30, 30, 0.01));
      for (var i = 0; i < _steps.last; i++) {
        final node = Node(
          mesh: Mesh(
            geometry,
            PhysicallyBasedMaterial()
              ..baseColorFactor = vm.Vector4(0.2, 0.5, 0.9, 0.02)
              ..alphaMode = AlphaMode.blend
              ..metallicFactor = 0
              ..roughnessFactor = 0.5,
          ),
        )..localTransform = vm.Matrix4.translationValues(0, 0, -i * 0.02);
        scene.add(node);
        _layers.add(node);
      }
      scene.add(
        Node(
          mesh: Mesh(
            CuboidGeometry(vm.Vector3.all(1)),
            PhysicallyBasedMaterial()
              ..baseColorFactor = vm.Vector4(0.9, 0.5, 0.2, 1),
          ),
        ),
      );
      rendererSubmissions
        ..addBeforeSubmitListener((_) {
          _lastSubmit = _clock.elapsedMicroseconds;
        })
        ..addCompletionListener(() {
          final done = rendererSubmissions.completedThrough;
          final now = _clock.elapsedMicroseconds;
          for (var id = _doneThrough + 1; id <= done; id++) {
            _doneAt[id] = now;
          }
          if (done > _doneThrough) _doneThrough = done;
          _flush();
        });
      setState(() => _scene = scene);
      _next();
    });
  }

  // A frame usually completes before the next tick closes it, so each id's
  // completion time is kept until its frame is known.
  void _flush() {
    while (_open.isNotEmpty && _open.first.lastId <= _doneThrough) {
      final f = _open.removeFirst();
      _times.add(_doneAt[f.lastId]! - f.tick);
      _doneAt.removeWhere((id, _) => id <= f.lastId);
    }
  }

  void _next() {
    if (++_limit == _limits.length) {
      _limit = 0;
      if (++_step == _steps.length) exit(0);
    }
    for (var i = 0; i < _layers.length; i++) {
      _layers[i].visible = i < _steps[_step];
    }
    _scene!.maxGpuFramesInFlight = _limits[_limit];
    _settle = 1;
  }

  void _reset() {
    _ticks = 0;
    _since = 0;
    _paced = _scene!.pacedFrameCount;
    _times.clear();
  }

  String _ms(double q) {
    if (_times.isEmpty) return '-';
    final s = List.of(_times)..sort();
    return (s[((s.length - 1) * q).round()] / 1000).toStringAsFixed(1);
  }

  void _onTick(double dt) {
    final scene = _scene!;
    final latest = rendererSubmissions.latestSubmission;
    if (latest > _closedId) {
      _open.add(_Frame(latest, _tickAt, _lastSubmit));
      _closedId = latest;
      _flush();
    }
    _tickAt = _clock.elapsedMicroseconds;
    if (_settle > 0) {
      if ((_settle -= dt) <= 0) _reset();
      return;
    }
    _ticks++;
    _since += dt;
    if (_since < _secondsPerLimit - 1) return;
    final shown = _ticks - (scene.pacedFrameCount - _paced);
    // ignore: avoid_print
    print(
      'PROBE layers=${_steps[_step]} limit=${_limits[_limit]} '
      'ticks=${(_ticks / _since).toStringAsFixed(1)} '
      'shown=${(shown / _since).toStringAsFixed(1)} '
      'frame50=${_ms(.5)}ms frame90=${_ms(.9)}ms',
    );
    _next();
  }

  @override
  Widget build(BuildContext context) {
    final scene = _scene;
    if (scene == null) return const SizedBox.expand();
    return SizedBox.expand(
      child: SceneView(scene, camera: _camera, onTick: (_, dt) => _onTick(dt)),
    );
  }
}
