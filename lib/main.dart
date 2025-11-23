import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'dart:async';

// ============================================================================
// LBS (Location Based Service) Constants - Production Ready
// ============================================================================
const double GPS_ACCURACY_THRESHOLD = 50.0; // metre - kötü sinyal eşiği
const double MIN_UPDATE_INTERVAL_SEC = 2.8; // saniye - throttling limiti
const double SIGNAL_LOSS_TIMEOUT_SEC = 5.0; // saniye - sinyal kayıp timeout
const double MAX_REASONABLE_SPEED_KMH = 250.0; // km/h - GPS jump koruması
const int RECOVERY_CONFIRM_COUNT = 3; // ardışık iyi sinyal sayısı
const double VIRTUAL_RECORD_ACCURACY = 9999.0; // sanal kayıt accuracy değeri
const int WARMUP_RECORD_COUNT = 10; // ilk 10 kayıt warm-up periyodu
const int WARMUP_SKIP_INITIAL_SAMPLES = 3; // ilk 3 kayıt ortalama hesabına girmez

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Konum Takip',
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.black),
      home: const LocationTrackerPage(),
    );
  }
}

class LocationTrackerPage extends StatefulWidget {
  const LocationTrackerPage({super.key});

  @override
  State<LocationTrackerPage> createState() => _LocationTrackerPageState();
}

class _LocationTrackerPageState extends State<LocationTrackerPage> {
  final List<LocationRecord> _locationHistory = [];
  final ScrollController _scrollController = ScrollController();

  StreamSubscription<Position>? _positionSubscription;
  Timer? _watchdogTimer; // Dead Reckoning watchdog

  String _statusMessage = 'Başlatılıyor...';
  DateTime? _startTime;
  DateTime? _lastProcessedTime; // Throttling ve watchdog için

  // Warm-up period için aritmetik ortalama
  final List<double> _warmupSpeedSamples = []; // Her kayıtın anlık hızı

  // Display metrics (kullanıcıya gösterilen)
  double _displayDistance = 0.0; // km
  double _displayElapsedSeconds = 0.0; // saniye (double hassasiyet)

  // Average calculation metrics (sadece iyi sinyal)
  double _avgDistance = 0.0; // km
  double _avgElapsedSeconds = 0.0; // saniye (double hassasiyet)
  double? _lastKnownAvgSpeedKmh;

  // Recovery state
  bool _waitingForRecovery = false;
  int _goodSignalRecoveryCount = 0;

  // Last known position for dead reckoning
  double? _lastKnownLat;
  double? _lastKnownLon;

  @override
  void initState() {
    super.initState();
    _initializeLocation();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _watchdogTimer?.cancel();
    _scrollController.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _initializeLocation() async {
    try {
      // Konum servisini kontrol et
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _statusMessage =
              'Konum servisi kapalı! Lütfen cihaz ayarlarından açın.';
        });
        return;
      }

      // İzin kontrolü
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() {
            _statusMessage = 'Konum izni reddedildi!';
          });
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _statusMessage =
              'Konum izni kalıcı olarak reddedildi! Uygulama ayarlarından izin verin.';
        });
        return;
      }

      // Android için arka plan konum izni iste
      if (permission == LocationPermission.whileInUse) {
        setState(() {
          _statusMessage = 'Arka plan izni isteniyor...';
        });

        // Arka plan izni için permission_handler kullan
        var backgroundStatus = await Permission.locationAlways.request();

        if (backgroundStatus.isDenied) {
          setState(() {
            _statusMessage =
                'Uyarı: Arka plan izni verilmedi. Sadece ön planda çalışacak.';
          });
        }
      }

      // İzinler alındı, takibi başlat
      setState(() {
        _statusMessage = 'Konum alınıyor...';
      });

      _startTracking();
    } catch (e) {
      setState(() {
        _statusMessage = 'Başlatma hatası: $e';
      });
      print('Konum başlatma hatası: $e');
    }
  }

  void _startTracking() {
    // Ekranı açık tut
    WakelockPlus.enable();

    // Platform bazlı ayarlar
    final LocationSettings locationSettings;

    if (Theme.of(context).platform == TargetPlatform.iOS) {
      // iOS için özel ayarlar - arka plan optimizasyonu
      locationSettings = AppleSettings(
        accuracy: LocationAccuracy.high,
        // Simülatörde iyi çalışan ama gerçek cihazda bekleyen tek kayıt
        // sorununu çözmek için mesafe filtresini sıfıra çektik; zaman
        // bazlı güncellemeler gelsin diye.
        distanceFilter: 0,
        pauseLocationUpdatesAutomatically: false,
        activityType: ActivityType.automotiveNavigation,
        showBackgroundLocationIndicator: true,
      );
    } else {
      // Android için özel ayarlar - zaman odaklı
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0, // Zaman bazlı güncelleme
        forceLocationManager: false,
        intervalDuration: const Duration(seconds: 3),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationText: "Konum takibi aktif - Arka planda çalışıyor",
          notificationTitle: "Konum Takip",
          enableWakeLock: true,
        ),
      );
    }

    // Watchdog timer - sinyal kaybı kontrolü ve dead reckoning
    _watchdogTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _checkSignalLoss();
    });

    _positionSubscription =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
          (Position position) {
            _processLocationUpdate(position);
          },
          onError: (error) {
            setState(() {
              _statusMessage = 'Konum hatası: $error';
            });
            debugPrint('Konum stream hatası: $error');
          },
        );
  }

  /// Sinyal kaybını kontrol eder ve gerekirse Dead Reckoning uygular
  void _checkSignalLoss() {
    if (_lastProcessedTime == null) return;

    // Warm-up sırasında recovery / dead reckoning devreye girmesin
    if (_locationHistory.length < WARMUP_RECORD_COUNT) return;

    // Düşük hızda (ışıkta durma vb.) sanal kayıt üretme
    final double lastSpeedMs =
        _locationHistory.isNotEmpty ? (_locationHistory.last.speed ?? 0.0) : 0.0;
    final double fallbackSpeedMs = _lastKnownAvgSpeedKmh != null
        ? _lastKnownAvgSpeedKmh! / 3.6
        : 0.0;
    final double effectiveSpeedMs =
        lastSpeedMs > 0 ? lastSpeedMs : fallbackSpeedMs;
    if (effectiveSpeedMs < 2.0) return; // <7 km/sa: recovery devreye girmez

    final now = DateTime.now();
    final secondsSinceLastUpdate =
        now.difference(_lastProcessedTime!).inMilliseconds / 1000.0;

    if (secondsSinceLastUpdate >= SIGNAL_LOSS_TIMEOUT_SEC) {
      // Sinyal kayıp - Dead Reckoning uygula
      if (_lastKnownAvgSpeedKmh != null && _lastKnownAvgSpeedKmh! > 0) {
        setState(() {
          // Geçen süreyi hesapla
          final timeDiffSec = secondsSinceLastUpdate;
          final estimatedDistance =
              _lastKnownAvgSpeedKmh! * (timeDiffSec / 3600.0); // km

          _displayDistance += estimatedDistance;
          _displayElapsedSeconds += timeDiffSec;

          // Sanal kayıt ekle
          _locationHistory.add(
            LocationRecord(
              latitude: _lastKnownLat ?? 0.0,
              longitude: _lastKnownLon ?? 0.0,
              timestamp: now,
              accuracy: VIRTUAL_RECORD_ACCURACY,
              altitude: null,
              speed: _lastKnownAvgSpeedKmh! / 3.6, // km/h -> m/s
              totalDistance: _displayDistance,
              averageDistance: _avgDistance,
              elapsedTime: now.difference(_startTime!),
              effectiveElapsedSeconds: _avgElapsedSeconds,
              isVirtual: true,
            ),
          );

          _lastProcessedTime = now;
          _statusMessage = 'Sinyal Kayıp - Dead Reckoning Aktif';

          _scrollToBottom();
        });
      }
    }
  }

  /// Ana konum işleme fonksiyonu - tüm mantık burada
  void _processLocationUpdate(Position position) {
    final now = DateTime.now();

    // THROTTLING: Minimum interval kontrolü
    if (_lastProcessedTime != null) {
      final secondsSinceLastProcess =
          now.difference(_lastProcessedTime!).inMilliseconds / 1000.0;
      if (secondsSinceLastProcess < MIN_UPDATE_INTERVAL_SEC) {
        return; // Çok erken güncelleme, atla
      }
    }

    setState(() {
      // İlk kayıt ise başlangıç zamanını kaydet
      if (_startTime == null) {
        _startTime = now;
        _lastProcessedTime = now;
      }

      // GPS sinyal kalitesini kontrol et
      // Warm-up fazında daha esnek, normal fazda daha sıkı
      final double currentSpeedMs = position.speed; // m/s
      final bool isLowSpeed = currentSpeedMs < 2.0; // 2 m/s ≈ 7 km/h
      final bool isWarmupPhase = _locationHistory.length < WARMUP_RECORD_COUNT;

      // Warm-up: 500m eşik (çok çok esnek - gerçek iPhone için)
      // Normal + Düşük hız: 100m eşik (esnek)
      // Normal + Hızlı: 50m eşik (sıkı)
      final double accuracyThreshold = isWarmupPhase
          ? 500.0
          : (isLowSpeed ? 100.0 : GPS_ACCURACY_THRESHOLD);
      final bool isGoodSignal = position.accuracy <= accuracyThreshold;

      debugPrint(
        '📍 GPS: accuracy=${position.accuracy.toStringAsFixed(1)}m, '
        'speed=${(currentSpeedMs * 3.6).toStringAsFixed(1)} km/h, '
        'isGoodSignal=$isGoodSignal, warmup=$isWarmupPhase',
      );

      // Geçen süreyi hesapla (DOUBLE HASSASİYET)
      final elapsed = now.difference(_startTime!);

      // WARM-UP KONTROLÜ: İlk 10 kayıt mı?
      if (_locationHistory.length < WARMUP_RECORD_COUNT) {
        if (_locationHistory.isNotEmpty) {
          final timeDiffMs = now.difference(_lastProcessedTime!).inMilliseconds;
          final timeDiffSec = timeDiffMs / 1000.0;

          if (timeDiffSec > 0) {
            final lastLocation = _locationHistory.last;

            // Mesafe hesapla
            final distanceMeters = Geolocator.distanceBetween(
              lastLocation.latitude,
              lastLocation.longitude,
              position.latitude,
              position.longitude,
            );
            final distanceKm = distanceMeters / 1000.0;

            // Anlık hız hesapla (km/h)
            final instantSpeedKmh = (distanceKm / timeDiffSec) * 3600.0;

            final bool canUseForWarmupAvg =
                _locationHistory.length >= WARMUP_SKIP_INITIAL_SAMPLES;

            // Warm-up: İyi sinyal + makul hız kontrolü + ilk 2 kaydı ortalama dışı
            if (isGoodSignal && instantSpeedKmh <= MAX_REASONABLE_SPEED_KMH) {
              // Hareketi ekrana yansıt
              _displayDistance += distanceKm;
              _displayElapsedSeconds += timeDiffSec;

              // Son bilinen konumu güncelle
              _lastKnownLat = position.latitude;
              _lastKnownLon = position.longitude;

              if (canUseForWarmupAvg) {
                // Anlık hızı listeye ekle (sıfır hız dahil)
                _warmupSpeedSamples.add(instantSpeedKmh);

                if (_warmupSpeedSamples.isNotEmpty) {
                  final sumSpeed = _warmupSpeedSamples.reduce((a, b) => a + b);
                  _lastKnownAvgSpeedKmh = sumSpeed / _warmupSpeedSamples.length;
                }
              }
            } else if (!isGoodSignal) {
              // Kötü sinyal - tahmini mesafe ekle
              if (_lastKnownAvgSpeedKmh != null) {
                final estimatedDistance =
                    _lastKnownAvgSpeedKmh! * (timeDiffSec / 3600.0);
                _displayDistance += estimatedDistance;
                _displayElapsedSeconds += timeDiffSec;
              }
            }
            // GPS jump durumunda (instantSpeedKmh > 250) hiçbir şey ekleme
          }
        } else {
          // İlk kayıt
          _lastKnownLat = position.latitude;
          _lastKnownLon = position.longitude;
        }

        // Warm-up kaydı ekle
        _locationHistory.add(
          LocationRecord(
            latitude: position.latitude,
            longitude: position.longitude,
            timestamp: now,
            accuracy: position.accuracy,
            altitude: position.altitude,
            speed: position.speed,
            totalDistance: _displayDistance,
            averageDistance: 0.0,
            elapsedTime: elapsed,
            effectiveElapsedSeconds: 0.0,
            isVirtual: false,
          ),
        );

        _lastProcessedTime = now;
        _statusMessage =
            'Warm-up: ${_locationHistory.length}/$WARMUP_RECORD_COUNT kayıt';
      } else {
        // WARM-UP TAMAMLANDI - Normal ortalama hesabına geç
        if (_locationHistory.length == WARMUP_RECORD_COUNT) {
          _avgDistance = _displayDistance;
          _avgElapsedSeconds = _displayElapsedSeconds;
        }

        if (_locationHistory.isNotEmpty) {
          final timeDiffMs = now.difference(_lastProcessedTime!).inMilliseconds;
          final timeDiffSec = timeDiffMs / 1000.0;

          if (timeDiffSec > 0) {
            final lastLocation = _locationHistory.last;

            final distanceMeters = Geolocator.distanceBetween(
              lastLocation.latitude,
              lastLocation.longitude,
              position.latitude,
              position.longitude,
            );
            final distanceKm = distanceMeters / 1000.0;
            final instantSpeedKmh = (distanceKm / timeDiffSec) * 3600.0;

            if (isGoodSignal && instantSpeedKmh <= MAX_REASONABLE_SPEED_KMH) {
              // İyi sinyal ve makul hız - normal işlem
              _displayDistance += distanceKm;
              _displayElapsedSeconds += timeDiffSec;
              _avgDistance += distanceKm;
              _avgElapsedSeconds += timeDiffSec;

              _lastKnownLat = position.latitude;
              _lastKnownLon = position.longitude;

              if (_waitingForRecovery) {
                _goodSignalRecoveryCount++;
                if (_goodSignalRecoveryCount >= RECOVERY_CONFIRM_COUNT) {
                  _waitingForRecovery = false;
                  _goodSignalRecoveryCount = 0;
                  _statusMessage = 'GPS Sinyali İyi';
                }
              }
            } else {
              // Kötü sinyal veya GPS sıçraması
              // RECOVERY MODE: Sadece araç hızlıyken (>7 km/h) uygula
              // Araç yavaş/duruyorsa sadece süre geçsin, ortalama düşsün
              final bool shouldUseRecovery = currentSpeedMs >= 2.0; // 7 km/h

              if (shouldUseRecovery) {
                // Araç hızlı, sinyal kötü → Dead Reckoning
                if (!_waitingForRecovery) {
                  _waitingForRecovery = true;
                  _goodSignalRecoveryCount = 0;
                }

                final estimatedDistance =
                    (_lastKnownAvgSpeedKmh ?? 0.0) * (timeDiffSec / 3600.0);
                _displayDistance += estimatedDistance;
                _displayElapsedSeconds += timeDiffSec;

                _statusMessage = isGoodSignal
                    ? 'GPS Sıçraması Tespit Edildi'
                    : 'GPS Sinyali Zayıf';
              } else {
                // Araç yavaş/duruyor, sinyal kötü → Sadece süre geçsin
                // Mesafe ekleme, ortalama düşsün
                _displayElapsedSeconds += timeDiffSec;
                _avgElapsedSeconds += timeDiffSec;

                _statusMessage = 'Düşük Hız - GPS Zayıf (Ortalama Düşüyor)';
              }
            }
          }
        }

        if (_avgElapsedSeconds > 0) {
          _lastKnownAvgSpeedKmh = _avgDistance / (_avgElapsedSeconds / 3600.0);
        }

        _locationHistory.add(
          LocationRecord(
            latitude: position.latitude,
            longitude: position.longitude,
            timestamp: now,
            accuracy: position.accuracy,
            altitude: position.altitude,
            speed: position.speed,
            totalDistance: _displayDistance,
            averageDistance: _avgDistance,
            elapsedTime: elapsed,
            effectiveElapsedSeconds: _avgElapsedSeconds,
            isVirtual: false,
          ),
        );

        _lastProcessedTime = now;
        if (!_waitingForRecovery) {
          _statusMessage = 'Kayıt: ${_locationHistory.length}';
        }
      }
    });

    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.day.toString().padLeft(2, '0')}/'
        '${dateTime.month.toString().padLeft(2, '0')}/'
        '${dateTime.year} '
        '${dateTime.hour.toString().padLeft(2, '0')}:'
        '${dateTime.minute.toString().padLeft(2, '0')}:'
        '${dateTime.second.toString().padLeft(2, '0')}';
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  double? _currentAverageKmh(bool lastRecordGoodSignal) {
    // Warm-up periyodunda aritmetik ortalama kullan
    if (_locationHistory.length < WARMUP_RECORD_COUNT) {
      return _lastKnownAvgSpeedKmh;
    }

    // Normal periyotta mesafe/süre bazlı ortalama
    if (_avgElapsedSeconds <= 0) return null;

    // Kötü sinyalde ekranda son bilinen ortalamayı koru
    if (!lastRecordGoodSignal && _lastKnownAvgSpeedKmh != null) {
      return _lastKnownAvgSpeedKmh;
    }
    return _avgDistance / (_avgElapsedSeconds / 3600.0);
  }

  String _formatMetric(String label, String? value) {
    return '$label: ${value ?? '-'}';
  }

  @override
  Widget build(BuildContext context) {
    final bool hasData = _locationHistory.isNotEmpty;
    final record = hasData ? _locationHistory.last : null;
    final bool lastRecordLowSpeed =
        record?.speed != null ? record!.speed! < 2.0 : false; // <7 km/sa
    final double lastRecordAccuracyThreshold =
        lastRecordLowSpeed ? 100.0 : GPS_ACCURACY_THRESHOLD;
    final lastRecordGoodSignal = record != null &&
        record.accuracy != null &&
        record.accuracy! <= lastRecordAccuracyThreshold;
    final currentAvg = _currentAverageKmh(lastRecordGoodSignal);
    final speedKmh = record?.speed != null ? (record!.speed! * 3.6) : null;
    final elapsedDuration = Duration(seconds: _displayElapsedSeconds.round());

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _locationHistory.isEmpty
            ? Center(
                child: Text(
                  _statusMessage,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Özet',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _formatMetric(
                            'Anlık hız',
                            speedKmh != null
                                ? '${speedKmh.toStringAsFixed(2)} km/sa'
                                : '-',
                          ),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          _formatMetric(
                            'Ortalama hız',
                            currentAvg != null
                                ? '${currentAvg.toStringAsFixed(2)} km/sa'
                                : '-',
                          ),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          _formatMetric(
                            'Mesafe',
                            hasData
                                ? '${_displayDistance.toStringAsFixed(3)} km'
                                : '-',
                          ),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          _formatMetric(
                            'Geçen süre',
                            _formatDuration(elapsedDuration),
                          ),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: Colors.white24, height: 1),
                  Expanded(
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(8),
                      itemCount: _locationHistory.length,
                      itemBuilder: (context, index) {
                        final record = _locationHistory[index];
                        final speedKmh = record.speed != null
                            ? (record.speed! * 3.6)
                            : 0.0;

                        // Ortalama hız hesapla
                        String avgSpeedText = '-';

                        // Warm-up periyodunda (ilk 10 kayıt)
                        if (index < WARMUP_RECORD_COUNT) {
                          // İLK KAYIT: Ortalama gösterme (henüz hesaplanamıyor)
                          if (index == 0) {
                            avgSpeedText = 'Hesaplanıyor...';
                          } else if (index - 1 < _warmupSpeedSamples.length) {
                            // index=1 için warmupSamples[0], index=2 için warmupSamples[0..1]
                            final samplesUpToNow = _warmupSpeedSamples.sublist(
                              0,
                              index,
                            );
                            if (samplesUpToNow.isNotEmpty) {
                              final sumSpeed = samplesUpToNow.reduce(
                                (a, b) => a + b,
                              );
                              final avgSpeed = sumSpeed / samplesUpToNow.length;
                              avgSpeedText =
                                  '${avgSpeed.toStringAsFixed(2)} (W)';
                            }
                          } else {
                            avgSpeedText = 'Hesaplanıyor...';
                          }
                        } else {
                          // Normal ortalama göster
                          final bool recordHasGoodSignal =
                              (record.accuracy != null &&
                              record.accuracy! <= GPS_ACCURACY_THRESHOLD);

                          if (recordHasGoodSignal &&
                              record.effectiveElapsedSeconds > 0) {
                            final elapsedHours =
                                record.effectiveElapsedSeconds / 3600.0;
                            final avgSpeedKmh =
                                record.averageDistance / elapsedHours;
                            avgSpeedText = avgSpeedKmh.toStringAsFixed(2);
                          } else if (_lastKnownAvgSpeedKmh != null) {
                            avgSpeedText = _lastKnownAvgSpeedKmh!
                                .toStringAsFixed(2);
                          }
                        }

                        // GPS sinyal durumu veya sanal kayıt kontrolü
                        String statusText;
                        if (record.isVirtual) {
                          statusText = ' | 🔴 SANAL KAYIT (Dead Reckoning)';
                        } else if (record.accuracy == null ||
                            record.accuracy! > GPS_ACCURACY_THRESHOLD) {
                          statusText = ' | ⚠️ GPS Zayıf';
                        } else {
                          statusText =
                              ' | ✅ ${record.accuracy!.toStringAsFixed(1)}m';
                        }

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            '${index + 1}. ${record.latitude.toStringAsFixed(6)}, ${record.longitude.toStringAsFixed(6)}\n'
                            '   ${_formatDateTime(record.timestamp)} | ${_formatDuration(record.elapsedTime)} | ${speedKmh.toStringAsFixed(2)} km/h\n'
                            '   Yol: ${record.totalDistance.toStringAsFixed(3)} km | Ort: $avgSpeedText km/h$statusText',
                            style: TextStyle(
                              color: record.isVirtual
                                  ? Colors.orange
                                  : Colors.white,
                              fontSize: 13,
                              fontFamily: 'monospace',
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class LocationRecord {
  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final double? accuracy;
  final double? altitude;
  final double? speed;
  final double totalDistance; // Toplam mesafe (km)
  final double
  averageDistance; // Ortalama hesap için mesafe (yalnızca iyi sinyal)
  final Duration elapsedTime; // İlk kayıttan geçen süre
  final double
  effectiveElapsedSeconds; // GPS sinyali iyi olduğu zamanlar için geçen süre (double)
  final bool isVirtual; // Dead reckoning sanal kaydı mı?

  LocationRecord({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracy,
    this.altitude,
    this.speed,
    required this.totalDistance,
    required this.averageDistance,
    required this.elapsedTime,
    required this.effectiveElapsedSeconds,
    this.isVirtual = false,
  });
}
