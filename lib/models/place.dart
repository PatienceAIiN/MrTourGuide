import '../services/media_api.dart';

/// A destination shown on the home screen. `citySlug` links the place to its
/// experience videos in the backend (GET /videos?city=<slug>).
///
/// [image] can be a network URL (backend/city covers — high-res, creator
/// replaceable) or an asset path (offline fallback).
class Place {
  final String citySlug;
  final String title;
  final String location;
  final String image;
  final String description;
  final double rating;

  /// Number of user ratings — 0 means unrated (no stars shown).
  final int ratingCount;

  /// 3D model URL for MR/VR, when available for this place.
  final String? modelUrl;

  const Place({
    required this.citySlug,
    required this.title,
    required this.location,
    required this.image,
    required this.description,
    this.rating = 0,
    this.ratingCount = 0,
    this.modelUrl,
  });

  bool get isNetworkImage => image.startsWith('http');

  /// Live place card from the backend city catalog.
  factory Place.fromCity(City city) => Place(
        citySlug: city.slug,
        title: city.name,
        location: city.location,
        image: city.absoluteCoverUrl ?? 'assets/image/card1.png',
        description: city.description,
        rating: city.rating,
        ratingCount: city.ratingCount,
        modelUrl: city.modelUrl,
      );
}
