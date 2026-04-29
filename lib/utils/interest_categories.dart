// lib/utils/interest_categories.dart
import 'package:flutter/material.dart';
import 'constants.dart'; // interestBaseColor(), kInterestCategoryFallback, etc.

// ────────────────────────────────────────────────────────────────────────────
// Category → Interests mapping (single source of truth)
// ────────────────────────────────────────────────────────────────────────────
const Map<String, List<String>> kInterestCategories = {
  "Outdoors & Adventure": [
    "Hiking",
    "Beach trips",
    "Island hopping",
    "Camping",
    "Road trips",
    "Mountaineering",
    "Surfing",
    "Freediving",
    "Scuba diving",
    "Cycling",
    "Skateboarding",
  ],
  "Sports & Wellness": [
    "Basketball",
    "Volleyball",
    "Badminton",
    "Table tennis",
    "Football",
    "Gym",
    "Pilates",
    "Yoga",
    "Running",
    "Calisthenics",
    "CrossFit",
  ],
  "Arts & Creativity": [
    "Photography",
    "Videography",
    "Graphic design",
    "Drawing",
    "Painting",
    "Calligraphy",
    "3D modeling",
    "Crafting",
    "DIY / Crafts",
    "Writing",
    "Poetry",
  ],
  "Music & Performance": [
    "OPM",
    "K-pop",
    "J-pop",
    "Classical",
    "Hip-hop",
    "EDM",
    "Choir",
    "Guitar",
    "Piano",
    "Karaoke",
    "Live gigs",
  ],
  "Film, TV & Fandoms": [
    "Movies",
    "K-drama",
    "Anime",
    "Documentaries",
    "Stand-up comedy",
    "Theater",
    "Cosplay",
    "Podcasts",
    "YouTube",
    "Streaming binges",
  ],
  "Games & Esports": [
    "Mobile Legends",
    "Valorant",
    "Genshin Impact",
    "Nintendo",
    "PlayStation",
    "Xbox",
    "PC gaming",
    "Retro gaming",
    "Board games",
    "Card games",
    "Tabletop RPGs",
  ],
  "Food & Drink": [
    "Street food",
    "Seafood",
    "BBQ",
    "Hotpot",
    "Baking",
    "Cooking",
    "Coffee",
    "Boba tea",
    "Tea",
    "Vegan / Plant-based",
    "Foodie",
  ],
  "Travel & Culture": [
    "Traveling",
    "Museums",
    "Art galleries",
    "Heritage sites",
    "Festivals",
    "Local markets",
    "Language learning",
    "Cultural exchange",
    "Architecture",
    "History",
  ],
  "Tech & Learning": [
    "Programming",
    "UI/UX",
    "Robotics",
    "AR/VR",
    "Startups",
    "Personal finance",
    "Investing",
    "Science",
    "Astronomy",
    "Math",
    "Productivity hacks",
  ],
  "Lifestyle & Home": [
    "Fashion",
    "Thrifting",
    "Skincare",
    "Interior design",
    "Minimalism",
    "Journaling",
    "Bullet journal",
    "Gardening",
    "House plants",
    "Scented candles",
  ],
  "Community & Values": [
    "Volunteering",
    "Environmentalism",
    "Animal welfare",
    "Mental health advocacy",
    "Faith & spirituality",
    "Local community events",
    "Campus orgs",
    "Charity runs",
  ],
  "Pets & Animals": [
    "Dogs",
    "Cats",
    "Aquariums",
    "Birds",
    "Reptiles",
    "Pet training",
    "Wildlife",
  ],
  "Wheels & Machines": [
    "Motorcycles",
    "Scooters",
    "Cars",
    "Off-roading",
    "Detailing",
    "Motorsports",
  ],
};

// ────────────────────────────────────────────────────────────────────────────
// Normalization + Fast Lookup Index
// - Lowercase
// - Treat spaces, hyphens, and underscores the same
// - Collapse multiple separators
// ────────────────────────────────────────────────────────────────────────────
String _normalize(String s) =>
    s.trim().toLowerCase().replaceAll(RegExp(r'[\s\-_]+'), ' ');

// Build interest → category index once.
final Map<String, String> _interestToCategoryIndex = (() {
  final map = <String, String>{};
  kInterestCategories.forEach((category, items) {
    for (final item in items) {
      map[_normalize(item)] = category;
    }
  });
  return map;
})();

// Public API
String? categoryForInterest(String label) {
  if (label.isEmpty) return null;
  return _interestToCategoryIndex[_normalize(label)];
}

// Color to use for an interest pill (category-based from constants.dart)
Color interestColorForLabel(String label) {
  final cat = categoryForInterest(label);
  return interestBaseColor(cat ?? "");
}
