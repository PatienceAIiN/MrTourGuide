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

  const Place({
    required this.citySlug,
    required this.title,
    required this.location,
    required this.image,
    required this.description,
    this.rating = 4.0,
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
      );
}

const kPlaces = [
  Place(
    citySlug: 'jaipur',
    title: 'Hawa Mahal',
    location: 'Jaipur, Rajasthan',
    image: 'assets/image/card1.png',
    rating: 4.5,
    description:
        'The "Palace of Winds" rises in pink sandstone above Jaipur\'s bazaars. '
        'Its 953 latticed windows once let royal ladies watch street festivals '
        'unseen — and let the desert breeze cool the palace naturally.',
  ),
  Place(
    citySlug: 'agra',
    title: 'Taj Mahal',
    location: 'Agra, Uttar Pradesh',
    image: 'assets/image/card2.png',
    rating: 4.0,
    description:
        'The Taj Mahal is an ivory-white marble mausoleum on the right bank '
        'of the Yamuna in Agra. It was commissioned in 1632 by the Mughal '
        'emperor Shah Jahan to house the tomb of his favourite wife, Mumtaz '
        'Mahal; it also houses the tomb of Shah Jahan himself.',
  ),
  Place(
    citySlug: 'amritsar',
    title: 'Golden Temple',
    location: 'Amritsar, Punjab',
    image: 'assets/image/card3.png',
    rating: 4.8,
    description:
        'The gilded Harmandir Sahib is the holiest gurdwara of Sikhism, '
        'floating at the center of its sacred pool. Its kitchen serves free '
        'meals to up to 100,000 visitors a day — everyone welcome.',
  ),
  Place(
    citySlug: 'jaipur',
    title: 'Amber Fort',
    location: 'Jaipur, Rajasthan',
    image: 'assets/image/card4.png',
    rating: 4.6,
    description:
        'A honey-hued fortress of red sandstone and marble climbing the '
        'Aravalli hills. Mirror-lined halls, winding ramparts and elephant '
        'gates tell four centuries of Rajput history.',
  ),
];
