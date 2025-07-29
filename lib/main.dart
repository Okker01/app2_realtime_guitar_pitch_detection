import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audio_session/audio_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Professional Guitar Tuner',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        fontFamily: 'RobotoMono',
      ),
      home: PitchDetectorScreen(),
    );
  }
}

class PitchDetectorScreen extends StatefulWidget {
  @override
  _PitchDetectorScreenState createState() => _PitchDetectorScreenState();
}

class _PitchDetectorScreenState extends State<PitchDetectorScreen> {
  // Flutter Sound components
  FlutterSoundRecorder? _recorder;
  FlutterSoundPlayer? _player;
  bool _isRecorderInitialized = false;
  bool _isRecording = false;

  // Audio streaming
  StreamSubscription? _recordingDataSubscription;
  StreamController<Uint8List>? _audioStreamController;

  // Pitch detection results
  String _currentNote = "No Input";
  double _currentFrequency = 0.0;
  double _centsOffset = 0.0;
  double _confidence = 0.0;

  // Settings from SharedPreferences
  double _referencePitch = 440.0; // A4 reference
  double _tuningTolerance = 10.0; // cents
  bool _guitarMode = true;
  PitchAlgorithm _algorithm = PitchAlgorithm.yin;
  bool _keepScreenAwake = true;

  // Detection history and processing
  List<PitchDetection> _detectionHistory = [];
  List<double> _audioBuffer = [];
  static const int sampleRate = 44100;
  static const int bufferSize = 4096;
  Timer? _processingTimer;

  // Guitar tuning presets
  final Map<String, List<String>> _tuningPresets = {
    'Standard': ['E2', 'A2', 'D3', 'G3', 'B3', 'E4'],
    'Drop D': ['D2', 'A2', 'D3', 'G3', 'B3', 'E4'],
    'Open G': ['D2', 'G2', 'D3', 'G3', 'B3', 'D4'],
    'DADGAD': ['D2', 'A2', 'D3', 'G3', 'A3', 'D4'],
  };
  String _selectedTuning = 'Standard';

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    await _loadSettings();
    await _initializeAudio();
    if (_keepScreenAwake) {
      WakelockPlus.enable();
    }
  }

  Future<void> _cleanup() async {
    _processingTimer?.cancel();
    _recordingDataSubscription?.cancel();
    _audioStreamController?.close();

    if (_isRecorderInitialized && _recorder != null) {
      if (_isRecording) {
        await _recorder!.stopRecorder();
      }
      await _recorder!.closeRecorder();
    }

    await _player?.closePlayer();
    WakelockPlus.disable();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _referencePitch = prefs.getDouble('reference_pitch') ?? 440.0;
      _tuningTolerance = prefs.getDouble('tuning_tolerance') ?? 10.0;
      _guitarMode = prefs.getBool('guitar_mode') ?? true;
      _keepScreenAwake = prefs.getBool('keep_screen_awake') ?? true;
      _selectedTuning = prefs.getString('selected_tuning') ?? 'Standard';
      final algorithmIndex = prefs.getInt('algorithm') ?? 0;
      _algorithm = PitchAlgorithm.values[algorithmIndex];
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('reference_pitch', _referencePitch);
    await prefs.setDouble('tuning_tolerance', _tuningTolerance);
    await prefs.setBool('guitar_mode', _guitarMode);
    await prefs.setBool('keep_screen_awake', _keepScreenAwake);
    await prefs.setString('selected_tuning', _selectedTuning);
    await prefs.setInt('algorithm', _algorithm.index);
  }

  Future<void> _initializeAudio() async {
    try {
      // Request permissions
      final microphoneStatus = await Permission.microphone.request();
      if (microphoneStatus != PermissionStatus.granted) {
        _showErrorDialog('Microphone permission is required for pitch detection');
        return;
      }

      // Initialize audio session
      final session = await AudioSession.instance;
      await session.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth |
        AVAudioSessionCategoryOptions.defaultToSpeaker,
        avAudioSessionMode: AVAudioSessionMode.measurement,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          flags: AndroidAudioFlags.audibilityEnforced,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: true,
      ));

      // Initialize Flutter Sound
      _recorder = FlutterSoundRecorder();
      _player = FlutterSoundPlayer();

      await _recorder!.openRecorder();
      await _player!.openPlayer();

      setState(() {
        _isRecorderInitialized = true;
      });
    } catch (e) {
      print('Audio initialization error: $e');
      _showErrorDialog('Failed to initialize audio: $e');
    }
  }

  Future<void> _startListening() async {
    if (!_isRecorderInitialized || _recorder == null) return;

    try {
      setState(() {
        _isRecording = true;
        _currentNote = "Listening...";
        _audioBuffer.clear();
      });

      // Create stream controller for audio data
      _audioStreamController = StreamController<Uint8List>();
      _recordingDataSubscription = _audioStreamController!.stream.listen(
        _processAudioData,
        onError: (error) {
          print('Recording stream error: $error');
          _stopListening();
        },
      );

      // Start recording with the correct stream sink
      await _recorder!.startRecorder(
        toStream: _audioStreamController!.sink,
        codec: Codec.pcm16,
        numChannels: 1,
        sampleRate: sampleRate,
      );

      // Start pitch detection timer
      _processingTimer = Timer.periodic(Duration(milliseconds: 50), (_) {
        if (_audioBuffer.length >= bufferSize && _isRecording) {
          _performPitchDetection();
        }
      });
    } catch (e) {
      print('Start recording error: $e');
      _showErrorDialog('Failed to start recording: $e');
      _stopListening();
    }
  }

  Future<void> _stopListening() async {
    try {
      if (_recorder != null && _isRecording) {
        await _recorder!.stopRecorder();
      }
      _recordingDataSubscription?.cancel();
      _processingTimer?.cancel();
      _audioStreamController?.close();

      setState(() {
        _isRecording = false;
        _currentNote = "No Input";
        _currentFrequency = 0.0;
        _confidence = 0.0;
        _centsOffset = 0.0;
      });
    } catch (e) {
      print('Stop recording error: $e');
    }
  }

  void _processAudioData(Uint8List data) {
    try {
      final samples = <double>[];

      // Convert bytes to doubles (16-bit PCM)
      for (int i = 0; i < data.length; i += 2) {
        if (i + 1 < data.length) {
          int sample = data[i] | (data[i + 1] << 8);
          if (sample > 32767) sample -= 65536;
          samples.add(sample / 32768.0);
        }
      }

      _audioBuffer.addAll(samples);

      // Maintain buffer size
      if (_audioBuffer.length > bufferSize * 2) {
        _audioBuffer = _audioBuffer.sublist(_audioBuffer.length - bufferSize);
      }
    } catch (e) {
      print('Audio processing error: $e');
    }
  }

  void _performPitchDetection() {
    if (_audioBuffer.length < bufferSize) return;

    try {
      final buffer = _audioBuffer.sublist(0, bufferSize);
      double frequency;
      double confidence;

      switch (_algorithm) {
        case PitchAlgorithm.yin:
          final result = _yinPitchDetection(buffer);
          frequency = result['frequency'] ?? 0.0;
          confidence = result['confidence'] ?? 0.0;
          break;
        case PitchAlgorithm.autocorrelation:
          final result = _autocorrelationPitchDetection(buffer);
          frequency = result['frequency'] ?? 0.0;
          confidence = result['confidence'] ?? 0.0;
          break;
        case PitchAlgorithm.fft:
          final result = _simpleFftPitchDetection(buffer);
          frequency = result['frequency'] ?? 0.0;
          confidence = result['confidence'] ?? 0.0;
          break;
      }

      // Filter frequency range and confidence
      if (frequency > 70 && frequency < 2000 && confidence > 0.3) {
        final noteInfo = _frequencyToNote(frequency);

        // Guitar mode filtering
        if (_guitarMode && !_isValidGuitarNote(noteInfo['note']!)) {
          return;
        }

        if (mounted) {
          setState(() {
            _currentFrequency = frequency;
            _currentNote = noteInfo['note']!;
            _centsOffset = noteInfo['cents']!;
            _confidence = confidence;
          });
        }

        // Add to history
        _addToHistory(PitchDetection(
          note: _currentNote,
          frequency: frequency,
          cents: _centsOffset,
          confidence: confidence,
          timestamp: DateTime.now(),
        ));
      }
    } catch (e) {
      print('Pitch detection error: $e');
    }
  }

  Map<String, double> _yinPitchDetection(List<double> buffer) {
    try {
      final int bufferSize = buffer.length;
      final List<double> yinBuffer = List.filled(bufferSize ~/ 2, 0.0);

      // Step 1: Difference function
      for (int tau = 0; tau < bufferSize ~/ 2; tau++) {
        double sum = 0.0;
        for (int i = 0; i < bufferSize ~/ 2; i++) {
          final delta = buffer[i] - buffer[i + tau];
          sum += delta * delta;
        }
        yinBuffer[tau] = sum;
      }

      // Step 2: Cumulative mean normalized difference
      yinBuffer[0] = 1.0;
      double runningSum = 0.0;
      for (int tau = 1; tau < bufferSize ~/ 2; tau++) {
        runningSum += yinBuffer[tau];
        if (runningSum > 0) {
          yinBuffer[tau] *= tau / runningSum;
        }
      }

      // Step 3: Absolute threshold
      const double threshold = 0.1;
      int tau = 1;
      while (tau < bufferSize ~/ 2) {
        if (yinBuffer[tau] < threshold) {
          while (tau + 1 < bufferSize ~/ 2 && yinBuffer[tau + 1] < yinBuffer[tau]) {
            tau++;
          }
          break;
        }
        tau++;
      }

      if (tau == bufferSize ~/ 2 || yinBuffer[tau] >= threshold) {
        return {'frequency': 0.0, 'confidence': 0.0};
      }

      // Step 4: Parabolic interpolation
      double betterTau = tau.toDouble();
      if (tau > 0 && tau < bufferSize ~/ 2 - 1) {
        final s0 = yinBuffer[tau - 1];
        final s1 = yinBuffer[tau];
        final s2 = yinBuffer[tau + 1];
        final denominator = 2 * (2 * s1 - s2 - s0);
        if (denominator.abs() > 1e-10) {
          betterTau = tau + (s2 - s0) / denominator;
        }
      }

      final frequency = sampleRate / betterTau;
      final confidence = 1.0 - yinBuffer[tau];

      return {'frequency': frequency, 'confidence': confidence};
    } catch (e) {
      print('YIN detection error: $e');
      return {'frequency': 0.0, 'confidence': 0.0};
    }
  }

  Map<String, double> _autocorrelationPitchDetection(List<double> buffer) {
    try {
      final int bufferSize = buffer.length;
      final List<double> autocorr = List.filled(bufferSize, 0.0);

      // Calculate autocorrelation
      for (int lag = 0; lag < bufferSize; lag++) {
        for (int i = 0; i < bufferSize - lag; i++) {
          autocorr[lag] += buffer[i] * buffer[i + lag];
        }
      }

      // Find first peak after initial decline
      double maxValue = 0.0;
      int peakIndex = 0;

      final startSearch = (sampleRate / 2000).round();
      final endSearch = math.min((sampleRate / 80).round(), bufferSize);

      for (int i = startSearch; i < endSearch; i++) {
        if (autocorr[i] > maxValue) {
          maxValue = autocorr[i];
          peakIndex = i;
        }
      }

      if (peakIndex == 0 || autocorr[0] == 0) {
        return {'frequency': 0.0, 'confidence': 0.0};
      }

      final frequency = sampleRate / peakIndex;
      final confidence = maxValue / autocorr[0];

      return {'frequency': frequency, 'confidence': confidence.clamp(0.0, 1.0)};
    } catch (e) {
      print('Autocorrelation detection error: $e');
      return {'frequency': 0.0, 'confidence': 0.0};
    }
  }

  Map<String, double> _simpleFftPitchDetection(List<double> buffer) {
    try {
      // Simple magnitude-based frequency detection without external FFT library
      final int bufferSize = buffer.length;
      final List<double> magnitudes = List.filled(bufferSize ~/ 2, 0.0);

      // Simple DFT for demonstration (inefficient but works)
      for (int k = 1; k < bufferSize ~/ 2; k += 4) {  // Skip some calculations for performance
        double real = 0.0;
        double imag = 0.0;

        for (int n = 0; n < bufferSize; n += 2) {  // Skip some samples for performance
          final angle = -2.0 * math.pi * k * n / bufferSize;
          real += buffer[n] * math.cos(angle);
          imag += buffer[n] * math.sin(angle);
        }

        magnitudes[k] = math.sqrt(real * real + imag * imag);
      }

      // Find peak in frequency domain
      double maxMagnitude = 0.0;
      int peakIndex = 0;

      final minIndex = math.max(1, (80 * bufferSize / sampleRate).round());
      final maxIndex = math.min(magnitudes.length - 1, (2000 * bufferSize / sampleRate).round());

      for (int i = minIndex; i < maxIndex; i++) {
        if (magnitudes[i] > maxMagnitude) {
          maxMagnitude = magnitudes[i];
          peakIndex = i;
        }
      }

      if (peakIndex == 0) {
        return {'frequency': 0.0, 'confidence': 0.0};
      }

      final frequency = peakIndex * sampleRate / bufferSize;
      final avgMagnitude = magnitudes.where((m) => m > 0).fold(0.0, (a, b) => a + b) /
          magnitudes.where((m) => m > 0).length;
      final confidence = avgMagnitude > 0 ? (maxMagnitude / avgMagnitude).clamp(0.0, 1.0) / 100 : 0.0;

      return {'frequency': frequency, 'confidence': confidence};
    } catch (e) {
      print('FFT detection error: $e');
      return {'frequency': 0.0, 'confidence': 0.0};
    }
  }

  Map<String, dynamic> _frequencyToNote(double frequency) {
    final double noteNumber = 12 * (math.log(frequency / _referencePitch) / math.ln2) + 57; // A4 = 57
    final int roundedNote = noteNumber.round();
    final double cents = (noteNumber - roundedNote) * 100;

    const noteNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
    final int octave = (roundedNote ~/ 12) - 1;
    final String noteName = noteNames[roundedNote % 12];

    return {
      'note': '$noteName$octave',
      'cents': cents,
    };
  }

  bool _isValidGuitarNote(String note) {
    return _tuningPresets[_selectedTuning]!.contains(note);
  }

  void _addToHistory(PitchDetection detection) {
    _detectionHistory.add(detection);
    if (_detectionHistory.length > 100) {
      _detectionHistory.removeAt(0);
    }
  }

  Color _getTuningColor() {
    if (_confidence < 0.3) return Colors.grey;
    if (_centsOffset.abs() < _tuningTolerance) return Colors.green;
    if (_centsOffset.abs() < _tuningTolerance * 2) return Colors.orange;
    return Colors.red;
  }

  String _getTuningStatus() {
    if (_confidence < 0.3) return "No signal";
    if (_centsOffset.abs() < _tuningTolerance) return "✓ In tune";
    if (_centsOffset > 0) return "♯ Sharp (+${_centsOffset.toStringAsFixed(1)}¢)";
    return "♭ Flat (${_centsOffset.toStringAsFixed(1)}¢)";
  }

  void _playReferenceNote() async {
    if (_currentNote == "No Input") return;

    // Generate a simple sine wave tone for reference
    // This would need a more sophisticated implementation
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Reference tone: ${_currentNote} (${_currentFrequency.toStringAsFixed(1)} Hz)')),
    );
  }

  void _showErrorDialog(String message) {
    if (mounted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Error'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Professional Guitar Tuner'),
        backgroundColor: Colors.blueGrey[800],
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(Icons.settings),
            onPressed: _showSettingsDialog,
          ),
          IconButton(
            icon: Icon(Icons.history),
            onPressed: _showHistoryDialog,
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.blueGrey[900]!, Colors.blueGrey[700]!],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Tuning preset selector
              Card(
                color: Colors.blueGrey[800],
                child: Padding(
                  padding: EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Text('Tuning: ', style: TextStyle(color: Colors.white70)),
                      DropdownButton<String>(
                        value: _selectedTuning,
                        dropdownColor: Colors.blueGrey[800],
                        style: TextStyle(color: Colors.white),
                        onChanged: (value) {
                          setState(() => _selectedTuning = value!);
                          _saveSettings();
                        },
                        items: _tuningPresets.keys.map((tuning) {
                          return DropdownMenuItem(
                            value: tuning,
                            child: Text(tuning),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),

              SizedBox(height: 16),

              // Main pitch display
              Card(
                elevation: 8,
                color: Colors.grey[900],
                child: Padding(
                  padding: EdgeInsets.all(32.0),
                  child: Column(
                    children: [
                      Text(
                        _currentNote,
                        style: TextStyle(
                          fontSize: 64,
                          fontWeight: FontWeight.bold,
                          color: _getTuningColor(),
                        ),
                      ),
                      SizedBox(height: 12),
                      Text(
                        '${_currentFrequency.toStringAsFixed(2)} Hz',
                        style: TextStyle(
                          fontSize: 20,
                          color: Colors.grey[400],
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        _getTuningStatus(),
                        style: TextStyle(
                          fontSize: 18,
                          color: _getTuningColor(),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 16),
                      // Cents indicator
                      Container(
                        height: 8,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: Colors.grey[700],
                        ),
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: (_centsOffset.abs() / 50).clamp(0.0, 1.0),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              color: _getTuningColor(),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              SizedBox(height: 20),

              // Confidence and algorithm display
              Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: _confidence,
                      backgroundColor: Colors.grey[700],
                      valueColor: AlwaysStoppedAnimation<Color>(_getTuningColor()),
                    ),
                  ),
                  SizedBox(width: 12),
                  Text(
                    '${(_confidence * 100).toStringAsFixed(0)}%',
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
              Text(
                'Algorithm: ${_algorithm.toString().split('.').last.toUpperCase()}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),

              SizedBox(height: 24),

              // Controls
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton.icon(
                    onPressed: _isRecorderInitialized
                        ? (_isRecording ? _stopListening : _startListening)
                        : null,
                    icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                    label: Text(_isRecording ? 'Stop' : 'Start'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isRecording ? Colors.red[600] : Colors.green[600],
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: _playReferenceNote,
                    icon: Icon(Icons.volume_up),
                    label: Text('Reference'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue[600],
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                ],
              ),

              SizedBox(height: 20),

              // Guitar strings visualization
              if (_guitarMode) ...[
                Text(
                  'Guitar Strings (${_selectedTuning})',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: _tuningPresets[_selectedTuning]!.map((note) {
                    final isActive = _currentNote == note;
                    return Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isActive ? _getTuningColor() : Colors.grey[700],
                        border: Border.all(
                          color: isActive ? Colors.white : Colors.grey[600]!,
                          width: 2,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          note.replaceAll(RegExp(r'[0-9]'), ''),
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Settings'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text('Reference Pitch (A4)'),
                  subtitle: Slider(
                    value: _referencePitch,
                    min: 430.0,
                    max: 450.0,
                    divisions: 20,
                    label: '${_referencePitch.toStringAsFixed(1)} Hz',
                    onChanged: (value) {
                      setDialogState(() => _referencePitch = value);
                      setState(() => _referencePitch = value);
                    },
                  ),
                ),
                ListTile(
                  title: Text('Tuning Tolerance'),
                  subtitle: Slider(
                    value: _tuningTolerance,
                    min: 5.0,
                    max: 25.0,
                    divisions: 20,
                    label: '±${_tuningTolerance.toStringAsFixed(0)}¢',
                    onChanged: (value) {
                      setDialogState(() => _tuningTolerance = value);
                      setState(() => _tuningTolerance = value);
                    },
                  ),
                ),
                SwitchListTile(
                  title: Text('Guitar Mode'),
                  subtitle: Text('Filter to guitar notes only'),
                  value: _guitarMode,
                  onChanged: (value) {
                    setDialogState(() => _guitarMode = value);
                    setState(() => _guitarMode = value);
                  },
                ),
                SwitchListTile(
                  title: Text('Keep Screen Awake'),
                  value: _keepScreenAwake,
                  onChanged: (value) {
                    setDialogState(() => _keepScreenAwake = value);
                    setState(() => _keepScreenAwake = value);
                    if (value) {
                      WakelockPlus.enable();
                    } else {
                      WakelockPlus.disable();
                    }
                  },
                ),
                ListTile(
                  title: Text('Detection Algorithm'),
                  subtitle: DropdownButton<PitchAlgorithm>(
                    value: _algorithm,
                    onChanged: (value) {
                      setDialogState(() => _algorithm = value!);
                      setState(() => _algorithm = value!);
                    },
                    items: [
                      DropdownMenuItem(
                        value: PitchAlgorithm.yin,
                        child: Text('YIN (Recommended)'),
                      ),
                      DropdownMenuItem(
                        value: PitchAlgorithm.autocorrelation,
                        child: Text('Autocorrelation'),
                      ),
                      DropdownMenuItem(
                        value: PitchAlgorithm.fft,
                        child: Text('FFT (Simple)'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _saveSettings();
                Navigator.pop(context);
              },
              child: Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _showHistoryDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Detection History'),
        content: Container(
          width: double.maxFinite,
          height: 400,
          child: _detectionHistory.isEmpty
              ? Center(child: Text('No detections yet'))
              : ListView.builder(
            itemCount: _detectionHistory.length,
            itemBuilder: (context, index) {
              final detection = _detectionHistory.reversed.toList()[index];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: detection.cents.abs() < _tuningTolerance
                      ? Colors.green : Colors.orange,
                  child: Text(
                    detection.note.replaceAll(RegExp(r'[0-9]'), ''),
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                title: Text('${detection.note} (${detection.frequency.toStringAsFixed(1)} Hz)'),
                subtitle: Text(
                    '${detection.cents > 0 ? '+' : ''}${detection.cents.toStringAsFixed(1)}¢ | '
                        '${(detection.confidence * 100).toStringAsFixed(0)}% | '
                        '${detection.timestamp.toString().substring(11, 19)}'
                ),
                dense: true,
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _detectionHistory.clear());
              Navigator.pop(context);
            },
            child: Text('Clear'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }
}

enum PitchAlgorithm { yin, autocorrelation, fft }

class PitchDetection {
  final String note;
  final double frequency;
  final double cents;
  final double confidence;
  final DateTime timestamp;

  PitchDetection({
    required this.note,
    required this.frequency,
    required this.cents,
    required this.confidence,
    required this.timestamp,
  });
}