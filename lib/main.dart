import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'dart:async';

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
  String _statusMessage = 'Başlatılıyor...';
  double _totalDistance = 0.0; // Toplam mesafe (km)
  DateTime? _startTime; // İlk kayıt zamanı

  @override
  void initState() {
    super.initState();
    _initializeLocation();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _scrollController.dispose();
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
        var backgroundStatus = await ph.Permission.locationAlways.request();

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
    // Android için özel ayarlar - arka plan için
    final androidSettings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0, // Mesafe filtresi kaldırıldı - her konumu al
      forceLocationManager: false,
      intervalDuration: const Duration(seconds: 3),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationText: "Konum takibi aktif - Arka planda çalışıyor",
        notificationTitle: "Konum Takip",
        enableWakeLock: true,
      ),
    );

    _positionSubscription =
        Geolocator.getPositionStream(locationSettings: androidSettings).listen(
          (Position position) {
            setState(() {
              final now = DateTime.now();

              // İlk kayıt ise başlangıç zamanını kaydet
              if (_startTime == null) {
                _startTime = now;
              }

              // Geçen süreyi hesapla
              final elapsed = now.difference(_startTime!);

              // Önceki konum varsa VE 4. kayıttan sonraysa mesafe hesapla
              if (_locationHistory.isNotEmpty && _locationHistory.length >= 3) {
                final lastLocation = _locationHistory.last;
                final distance = Geolocator.distanceBetween(
                  lastLocation.latitude,
                  lastLocation.longitude,
                  position.latitude,
                  position.longitude,
                );
                _totalDistance += distance / 1000; // Metreyi km'ye çevir
              }

              _locationHistory.add(
                LocationRecord(
                  latitude: position.latitude,
                  longitude: position.longitude,
                  timestamp: now,
                  accuracy: position.accuracy,
                  altitude: position.altitude,
                  speed: position.speed,
                  totalDistance: _totalDistance,
                  elapsedTime: elapsed,
                ),
              );
              _statusMessage = 'Kayıt: ${_locationHistory.length}';
            });

            // Otomatik kaydırma
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_scrollController.hasClients) {
                _scrollController.animateTo(
                  _scrollController.position.maxScrollExtent,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                );
              }
            });
          },
          onError: (error) {
            setState(() {
              _statusMessage = 'Konum hatası: $error';
            });
            print('Konum stream hatası: $error');
          },
        );
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

  @override
  Widget build(BuildContext context) {
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
            : ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(8),
                itemCount: _locationHistory.length,
                itemBuilder: (context, index) {
                  final record = _locationHistory[index];
                  final speedKmh = record.speed != null
                      ? (record.speed! * 3.6)
                      : 0.0;

                  // Ortalama hız hesapla (Fizik: toplam yol / geçen süre)
                  // İlk 3 kayıt için ortalama hız hesaplama (GPS stabilizasyonu için)
                  String avgSpeedText = '-';
                  if (index >= 3 && record.elapsedTime.inSeconds > 0) {
                    final elapsedHours = record.elapsedTime.inSeconds / 3600.0;
                    final avgSpeedKmh =
                        record.totalDistance / elapsedHours; // km/saat
                    avgSpeedText = avgSpeedKmh.toStringAsFixed(2);
                  }

                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '${index + 1}. Enlem: ${record.latitude.toStringAsFixed(6)} | Boylam: ${record.longitude.toStringAsFixed(6)}\n'
                      '   Zaman: ${_formatDateTime(record.timestamp)} | Geçen: ${_formatDuration(record.elapsedTime)} | Hız: ${speedKmh.toStringAsFixed(2)} km/sa\n'
                      '   Yol: ${record.totalDistance.toStringAsFixed(3)} km | Ort.Hız: $avgSpeedText km/sa${record.accuracy != null ? ' | Doğruluk: ${record.accuracy!.toStringAsFixed(1)}m' : ''}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontFamily: 'monospace',
                      ),
                    ),
                  );
                },
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
  final Duration elapsedTime; // İlk kayıttan geçen süre

  LocationRecord({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracy,
    this.altitude,
    this.speed,
    required this.totalDistance,
    required this.elapsedTime,
  });
}
