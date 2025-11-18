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
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
      ),
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
          _statusMessage = 'Konum servisi kapalı! Lütfen cihaz ayarlarından açın.';
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
          _statusMessage = 'Konum izni kalıcı olarak reddedildi! Uygulama ayarlarından izin verin.';
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
            _statusMessage = 'Uyarı: Arka plan izni verilmedi. Sadece ön planda çalışacak.';
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
      distanceFilter: 5,
      forceLocationManager: false,
      intervalDuration: const Duration(seconds: 3),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationText: "Konum takibi aktif - Arka planda çalışıyor",
        notificationTitle: "Konum Takip",
        enableWakeLock: true,
      ),
    );

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: androidSettings,
    ).listen(
      (Position position) {
        setState(() {
          _locationHistory.add(LocationRecord(
            latitude: position.latitude,
            longitude: position.longitude,
            timestamp: DateTime.now(),
            accuracy: position.accuracy,
            altitude: position.altitude,
            speed: position.speed,
          ));
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _locationHistory.isEmpty
            ? Center(
                child: Text(
                  _statusMessage,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                  ),
                  textAlign: TextAlign.center,
                ),
              )
            : ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(8),
                itemCount: _locationHistory.length,
                itemBuilder: (context, index) {
                  final record = _locationHistory[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '${index + 1}. Enlem: ${record.latitude.toStringAsFixed(6)} | Boylam: ${record.longitude.toStringAsFixed(6)}\n'
                      '   Zaman: ${_formatDateTime(record.timestamp)}${record.accuracy != null ? ' | Doğruluk: ${record.accuracy!.toStringAsFixed(1)}m' : ''}',
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

  LocationRecord({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracy,
    this.altitude,
    this.speed,
  });
}
