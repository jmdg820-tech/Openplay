import 'package:geolocator/geolocator.dart';

import '../utils/geo.dart';

/// Wraps device geolocation with honest, non-throwing degradation: any
/// permission denial, disabled location service, or platform that doesn't
/// support it returns null instead of crashing the caller. "Nearby"
/// discovery is a nice-to-have, never a hard requirement to use the app.
class LocationService {
  Future<GeoPoint?> currentPosition() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      return GeoPoint(position.latitude, position.longitude);
    } catch (_) {
      // Any platform/plugin-level failure degrades to "unknown location",
      // never a crash.
      return null;
    }
  }
}
