import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

class YoloDetection {
  YoloDetection({
    required this.classId,
    required this.label,
    required this.score,
    required this.rect,
    required this.areaRatio,
    required this.proximity,
    required this.distanceMeters,
    this.sourceLabel,
  });

  final int classId;
  final String label;
  final double score;
  final Rect rect;
  final double areaRatio;
  final String proximity;
  final double? distanceMeters;
  final String? sourceLabel;
}

class _LetterboxResult {
  _LetterboxResult({
    required this.image,
    required this.scale,
    required this.padX,
    required this.padY,
    required this.inputSize,
    required this.origWidth,
    required this.origHeight,
  });

  final img.Image image;
  final double scale;
  final double padX;
  final double padY;
  final int inputSize;
  final int origWidth;
  final int origHeight;
}

class _TensorView {
  _TensorView(this.data, this.shape);

  final Float32List data;
  final List<int> shape;
}

class YoloDetectorService {
  YoloDetectorService({
    this.modelAsset = 'assets/models/best.onnx',
    this.labelsAsset = 'assets/models/road_labels.txt',
    this.inputSize = 640,
    this.cameraFovDegrees = 60.0,
    this.defaultObjectHeightM = 1.5,
    this.defaultObjectWidthM = 0.8,
    Map<String, double>? objectHeightsMeters,
    Map<String, double>? objectWidthsMeters,
  }) : objectHeightsMeters = objectHeightsMeters ??
            const {
              'door': 2.0,
              'openedDoor': 2.0,
              'cabinetDoor': 1.8,
              'refrigeratorDoor': 1.8,
              'window': 1.2,
              'chair': 1.0,
              'table': 0.75,
              'cabinet': 1.8,
              'sofa/couch': 1.0,
              'couch': 1.0,
              'pole': 2.5,
              'vehicle': 1.5,
              'living': 1.7,
              'roadside': 2.5,
              'electric_pole': 2.5,
              'road': 1.0,
              'car': 1.45,
              'bus': 3.0,
              'truck': 3.2,
              'motorcycle': 1.2,
              'ambulance': 2.4,
              'person': 1.7,
            },
       objectWidthsMeters = objectWidthsMeters ??
            const {
              'door': 0.9,
              'openedDoor': 0.9,
              'cabinetDoor': 0.55,
              'refrigeratorDoor': 0.65,
              'window': 1.2,
              'chair': 0.55,
              'table': 1.1,
              'cabinet': 1.0,
              'sofa/couch': 1.8,
              'couch': 1.8,
              'pole': 0.25,
              'vehicle': 1.9,
              'living': 0.45,
              'roadside': 1.0,
              'electric_pole': 0.35,
              'road': 3.0,
              'car': 1.8,
              'bus': 2.5,
              'truck': 2.6,
              'motorcycle': 0.8,
              'ambulance': 2.2,
              'person': 0.45,
            };

  final String modelAsset;
  final String labelsAsset;
  final int inputSize;
  final double cameraFovDegrees;
  final double defaultObjectHeightM;
  final double defaultObjectWidthM;

  final Map<String, double> objectHeightsMeters;
  final Map<String, double> objectWidthsMeters;

  OrtSession? _session;
  List<String> _labels = const [];
  bool _ready = false;

  bool get isReady => _ready;

  Future<void> initialize() async {
    if (_ready) return;
    final modelData = await rootBundle.load(modelAsset);
    final options = OrtSessionOptions();
    _session = OrtSession.fromBuffer(modelData.buffer.asUint8List(), options);
    final labelsRaw = await rootBundle.loadString(labelsAsset);
    _labels = labelsRaw
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    _ready = true;
  }

  Future<void> dispose() async {
    _session?.release();
    _session = null;
    _ready = false;
  }

  Future<List<YoloDetection>> detect(
    img.Image image, {
    double confThreshold = 0.35,
    double iouThreshold = 0.45,
  }) async {
    if (!_ready || _session == null) return [];

    final prep = _letterbox(image, inputSize);
    final inputTensor = _imageToTensor(prep.image, inputSize);

    final inputName = _session!.inputNames.first;
    final input = OrtValueTensor.createTensorWithDataList(
      inputTensor,
      [1, 3, inputSize, inputSize],
    );
    final outputs = _session!.run(OrtRunOptions(), {inputName: input});
    if (outputs.isEmpty) {
      input.release();
      return [];
    }

    final output = outputs.first;
    if (output == null) {
      input.release();
      return [];
    }

    final tensorInfo = _extractTensor(output);
    final Float32List data = tensorInfo.data;
    final List<int> shape = tensorInfo.shape;
    if (shape.length < 3) {
      input.release();
      for (final out in outputs) {
        out?.release();
      }
      return [];
    }

    final bool transposed = shape.length == 3 && shape[1] > shape[2];
    final int channels = transposed ? shape[2] : shape[1];
    final int numBoxes = transposed ? shape[1] : shape[2];
    final int numClasses = channels - 4;
    if (channels < 5 || numBoxes <= 0 || numClasses <= 0) {
      input.release();
      for (final out in outputs) {
        out?.release();
      }
      return [];
    }

    double valueAt(int boxIndex, int channelIndex) {
      if (transposed) {
        return data[boxIndex * channels + channelIndex];
      }
      return data[numBoxes * channelIndex + boxIndex];
    }

    final detections = <YoloDetection>[];
    for (int i = 0; i < numBoxes; i++) {
      final double cx = valueAt(i, 0);
      final double cy = valueAt(i, 1);
      final double w = valueAt(i, 2);
      final double h = valueAt(i, 3);

      double bestScore = 0.0;
      int bestClass = -1;
      for (int c = 0; c < numClasses; c++) {
        final double score = valueAt(i, 4 + c);
        if (score > bestScore) {
          bestScore = score;
          bestClass = c;
        }
      }
      if (bestScore < confThreshold || bestClass < 0) continue;

      final double x1 = cx - w / 2;
      final double y1 = cy - h / 2;
      final double x2 = cx + w / 2;
      final double y2 = cy + h / 2;

      final Rect rectInInput = Rect.fromLTRB(x1, y1, x2, y2);
      final Rect rect = _mapToOriginal(rectInInput, prep);
      final double areaRatio =
          (rect.width * rect.height) / (prep.origWidth * prep.origHeight);

      final label = bestClass < _labels.length ? _labels[bestClass] : 'class_$bestClass';
      final double? distanceMeters = _estimateDistanceMeters(
        rect: rect,
        imageWidth: prep.origWidth.toDouble(),
        imageHeight: prep.origHeight.toDouble(),
        label: label,
      );
      final String proximity = distanceMeters == null
          ? _proximityBucket(areaRatio)
          : _distanceBucket(distanceMeters);
      detections.add(
        YoloDetection(
          classId: bestClass,
          label: label,
          score: bestScore,
          rect: rect,
          areaRatio: areaRatio,
          proximity: proximity,
          distanceMeters: distanceMeters,
          sourceLabel: label,
        ),
      );
    }

    final nmsDetections = _nonMaxSuppression(detections, iouThreshold);
    for (final out in outputs) {
      out?.release();
    }
    input.release();
    return nmsDetections;
  }

  _LetterboxResult _letterbox(img.Image image, int size) {
    final int origW = image.width;
    final int origH = image.height;
    final double scale = min(size / origW, size / origH);
    final int newW = (origW * scale).round();
    final int newH = (origH * scale).round();
    final img.Image resized = img.copyResize(image, width: newW, height: newH);
    final img.Image canvas = img.Image(width: size, height: size);
    img.fill(canvas, color: img.ColorRgb8(0, 0, 0));
    final int padX = ((size - newW) / 2).round();
    final int padY = ((size - newH) / 2).round();
    img.compositeImage(canvas, resized, dstX: padX, dstY: padY);
    return _LetterboxResult(
      image: canvas,
      scale: scale,
      padX: padX.toDouble(),
      padY: padY.toDouble(),
      inputSize: size,
      origWidth: origW,
      origHeight: origH,
    );
  }

  Float32List _imageToTensor(img.Image image, int size) {
    final Float32List input = Float32List(1 * 3 * size * size);
    final int hw = size * size;
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final pixel = image.getPixel(x, y);
        final int r = pixel.r.toInt();
        final int g = pixel.g.toInt();
        final int b = pixel.b.toInt();
        final int index = y * size + x;
        input[index] = r / 255.0;
        input[hw + index] = g / 255.0;
        input[2 * hw + index] = b / 255.0;
      }
    }
    return input;
  }

  _TensorView _extractTensor(OrtValue output) {
    final dynamic value = output.value;
    if (value is Float32List) {
      return _TensorView(value, [value.length]);
    }
    if (value is List) {
      final shape = _inferShape(value);
      final flat = <double>[];
      _flatten(value, flat);
      return _TensorView(Float32List.fromList(flat), shape);
    }
    return _TensorView(Float32List(0), const [0]);
  }

  List<int> _inferShape(dynamic value) {
    final shape = <int>[];
    dynamic cursor = value;
    while (cursor is List) {
      shape.add(cursor.length);
      if (cursor.isEmpty) break;
      cursor = cursor.first;
    }
    return shape;
  }

  void _flatten(dynamic value, List<double> out) {
    if (value is List) {
      for (final item in value) {
        _flatten(item, out);
      }
      return;
    }
    if (value is num) {
      out.add(value.toDouble());
    }
  }

  Rect _mapToOriginal(Rect rect, _LetterboxResult prep) {
    final double x1 = (rect.left - prep.padX) / prep.scale;
    final double y1 = (rect.top - prep.padY) / prep.scale;
    final double x2 = (rect.right - prep.padX) / prep.scale;
    final double y2 = (rect.bottom - prep.padY) / prep.scale;
    return Rect.fromLTRB(
      x1.clamp(0.0, prep.origWidth.toDouble()),
      y1.clamp(0.0, prep.origHeight.toDouble()),
      x2.clamp(0.0, prep.origWidth.toDouble()),
      y2.clamp(0.0, prep.origHeight.toDouble()),
    );
  }

  String _proximityBucket(double areaRatio) {
    if (areaRatio >= 0.35) return 'near';
    if (areaRatio >= 0.18) return 'mid';
    return 'far';
  }

  String _distanceBucket(double distanceMeters) {
    if (distanceMeters <= 3.0) return 'urgent';
    if (distanceMeters <= 6.0) return 'near';
    if (distanceMeters <= 10.0) return 'mid';
    return 'far';
  }

  double? _estimateDistanceMeters({
    required Rect rect,
    required double imageWidth,
    required double imageHeight,
    required String label,
  }) {
    if (rect.height <= 1 || rect.width <= 1 || imageWidth <= 0 || imageHeight <= 0) {
      return null;
    }
    final normalized = label.trim().toLowerCase();
    if (_distanceIgnoredLabels.contains(normalized)) {
      return null;
    }
    final resolvedLabel = _resolveCanonicalLabel(label);
    final double objectHeightM = _lookupObjectHeight(resolvedLabel);
    final double objectWidthM = _lookupObjectWidth(resolvedLabel);

    final double verticalFovRadians = cameraFovDegrees * pi / 180.0;
    final double focalY = imageHeight / (2 * tan(verticalFovRadians / 2));
    final double horizontalFovRadians =
        2 * atan((imageWidth / imageHeight) * tan(verticalFovRadians / 2));
    final double focalX = imageWidth / (2 * tan(horizontalFovRadians / 2));

    double? fromHeight;
    if (objectHeightM > 0 && rect.height > 1) {
      final estimate = (objectHeightM * focalY) / rect.height;
      if (estimate.isFinite && estimate > 0) fromHeight = estimate;
    }
    double? fromWidth;
    if (objectWidthM > 0 && rect.width > 1) {
      final estimate = (objectWidthM * focalX) / rect.width;
      if (estimate.isFinite && estimate > 0) fromWidth = estimate;
    }

    double? distance;
    if (fromHeight != null && fromWidth != null) {
      final aspect = rect.height / rect.width;
      final heightWeight = aspect >= 1.0 ? 0.65 : 0.45;
      distance = fromHeight * heightWeight + fromWidth * (1.0 - heightWeight);
    } else {
      distance = fromHeight ?? fromWidth;
    }
    if (distance == null || !distance.isFinite || distance <= 0) return null;

    final calibration = _distanceCalibrationByLabel[resolvedLabel] ?? 1.0;
    final calibrated = distance * calibration;
    return calibrated.clamp(0.2, 50.0);
  }

  String _resolveCanonicalLabel(String label) {
    final normalized = _normalizeLabel(label);
    return _labelAliases[normalized] ?? normalized;
  }

  String _normalizeLabel(String label) {
    return label.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  double _lookupObjectHeight(String canonicalLabel) {
    for (final entry in objectHeightsMeters.entries) {
      if (_normalizeLabel(entry.key) == canonicalLabel) {
        return entry.value;
      }
    }
    return defaultObjectHeightM;
  }

  double _lookupObjectWidth(String canonicalLabel) {
    for (final entry in objectWidthsMeters.entries) {
      if (_normalizeLabel(entry.key) == canonicalLabel) {
        return entry.value;
      }
    }
    return defaultObjectWidthM;
  }

  static const Set<String> _distanceIgnoredLabels = {
    'drivable',
    'non_drivable',
    'far',
    'sky',
    'road',
  };

  static const Map<String, String> _labelAliases = {
    'openeddoor': 'door',
    'cabinetdoor': 'cabinetdoor',
    'refrigeratordoor': 'refrigeratordoor',
    'electricpole': 'pole',
    'powerpole': 'pole',
    'living': 'person',
    'person': 'person',
    'vehicle': 'car',
    'ambulance': 'ambulance',
    'motorcycle': 'motorcycle',
    'bus': 'bus',
    'truck': 'truck',
    'car': 'car',
  };

  static const Map<String, double> _distanceCalibrationByLabel = {
    'person': 0.95,
    'car': 0.92,
    'bus': 0.90,
    'truck': 0.90,
    'motorcycle': 0.92,
    'ambulance': 0.92,
    'door': 0.93,
    'cabinetdoor': 0.9,
    'refrigeratordoor': 0.9,
    'chair': 0.88,
    'table': 0.9,
    'couch': 0.92,
    'pole': 0.95,
  };

  List<YoloDetection> _nonMaxSuppression(List<YoloDetection> dets, double iouThreshold) {
    if (dets.isEmpty) return dets;
    final sorted = [...dets]..sort((a, b) => b.score.compareTo(a.score));
    final picked = <YoloDetection>[];
    while (sorted.isNotEmpty) {
      final current = sorted.removeAt(0);
      picked.add(current);
      sorted.removeWhere((d) => _iou(current.rect, d.rect) > iouThreshold);
    }
    return picked;
  }

  double _iou(Rect a, Rect b) {
    final double interLeft = max(a.left, b.left);
    final double interTop = max(a.top, b.top);
    final double interRight = min(a.right, b.right);
    final double interBottom = min(a.bottom, b.bottom);
    final double interWidth = max(0.0, interRight - interLeft);
    final double interHeight = max(0.0, interBottom - interTop);
    final double interArea = interWidth * interHeight;
    final double unionArea = a.width * a.height + b.width * b.height - interArea;
    if (unionArea <= 0) return 0;
    return interArea / unionArea;
  }
}
