// lib/screens/profile_setup/interest_page.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// App constants (colors, interestBaseColor, interestBorderColor, etc.)
import '../../utils/constants.dart';

// ✅ Single source of truth: shared categories map + helpers
import '../../utils/interest_categories.dart';

class InterestsPage extends StatefulWidget {
  final ValueChanged<List<String>> onInterestsSelected;
  final int minSelect;
  final int maxSelect;

  const InterestsPage({
    super.key,
    required this.onInterestsSelected,
    this.minSelect = 3,
    this.maxSelect = 10, // default to 10 per plan
  });

  @override
  State<InterestsPage> createState() => _InterestsPageState();
}

class _InterestsPageState extends State<InterestsPage> {
  // ---- persistence keys ----
  static const String _prefsKeyLabels = 'interests_labels_v1';
  static const String _prefsKeySlugs = 'interests_slugs_v1';

  // ───────────────────────────────────────────────
  // Catalog (single source of truth)
  // ───────────────────────────────────────────────
  // Use the shared map so InterestsPage and ProfileScreen stay in sync.
  final Map<String, List<String>> interestCategories = kInterestCategories;

  // Optional icons for labels (falls back gracefully)
  final Map<String, IconData> interestIcons = const {
    // Outdoors & Adventure
    "Hiking": Icons.terrain,
    "Beach trips": Icons.beach_access,
    "Island hopping": Icons.sailing,
    "Camping": Icons.park,
    "Road trips": Icons.map,
    "Mountaineering": Icons.landscape,
    "Surfing": Icons.water,
    "Freediving": Icons.water,
    "Scuba diving": Icons.waves,
    "Cycling": Icons.directions_bike,
    "Skateboarding": Icons.skateboarding,

    // Sports & Wellness
    "Basketball": Icons.sports_basketball,
    "Volleyball": Icons.sports_volleyball,
    "Badminton": Icons.sports_tennis,
    "Table tennis": Icons.sports_tennis,
    "Football": Icons.sports_soccer,
    "Gym": Icons.fitness_center,
    "Pilates": Icons.self_improvement,
    "Yoga": Icons.self_improvement,
    "Running": Icons.directions_run,
    "Calisthenics": Icons.fitness_center,
    "CrossFit": Icons.fitness_center,

    // Arts & Creativity
    "Photography": Icons.photo_camera,
    "Videography": Icons.videocam,
    "Graphic design": Icons.design_services,
    "Drawing": Icons.brush,
    "Painting": Icons.color_lens,
    "Calligraphy": Icons.edit,
    "3D modeling": Icons.view_in_ar,
    "Crafting": Icons.cut,
    "DIY / Crafts": Icons.handyman,
    "Writing": Icons.create,
    "Poetry": Icons.menu_book,

    // Music & Performance
    "OPM": Icons.music_note,
    "K-pop": Icons.library_music,
    "J-pop": Icons.library_music,
    "Classical": Icons.music_note,
    "Hip-hop": Icons.graphic_eq,
    "EDM": Icons.equalizer,
    "Choir": Icons.queue_music,
    "Guitar": Icons.queue_music,
    "Piano": Icons.music_note,
    "Karaoke": Icons.mic,
    "Live gigs": Icons.event,

    // Film, TV & Fandoms
    "Movies": Icons.movie,
    "K-drama": Icons.live_tv,
    "Anime": Icons.emoji_emotions,
    "Documentaries": Icons.theaters,
    "Stand-up comedy": Icons.mood,
    "Theater": Icons.theaters,
    "Cosplay": Icons.face_retouching_natural,
    "Podcasts": Icons.headphones,
    "YouTube": Icons.ondemand_video,
    "Streaming binges": Icons.tv,

    // Games & Esports
    "Mobile Legends": Icons.sports_esports,
    "Valorant": Icons.sports_esports,
    "Genshin Impact": Icons.sports_esports,
    "Nintendo": Icons.videogame_asset,
    "PlayStation": Icons.videogame_asset,
    "Xbox": Icons.videogame_asset,
    "PC gaming": Icons.computer,
    "Retro gaming": Icons.memory,
    "Board games": Icons.extension,
    "Card games": Icons.style,
    "Tabletop RPGs": Icons.menu_book,

    // Food & Drink
    "Street food": Icons.ramen_dining,
    "Seafood": Icons.set_meal,
    "BBQ": Icons.outdoor_grill,
    "Hotpot": Icons.ramen_dining,
    "Baking": Icons.cake,
    "Cooking": Icons.restaurant_menu,
    "Coffee": Icons.coffee,
    "Boba tea": Icons.emoji_food_beverage,
    "Tea": Icons.local_cafe,
    "Vegan / Plant-based": Icons.eco,
    "Foodie": Icons.fastfood,

    // Travel & Culture
    "Traveling": Icons.flight_takeoff,
    "Museums": Icons.museum,
    "Art galleries": Icons.palette,
    "Heritage sites": Icons.account_balance,
    "Festivals": Icons.celebration,
    "Local markets": Icons.storefront,
    "Language learning": Icons.translate,
    "Cultural exchange": Icons.public,
    "Architecture": Icons.apartment,
    "History": Icons.history_edu,

    // Tech & Learning
    "Programming": Icons.code,
    "UI/UX": Icons.devices,
    "Robotics": Icons.precision_manufacturing,
    "AR/VR": Icons.view_in_ar,
    "Startups": Icons.rocket_launch,
    "Personal finance": Icons.savings,
    "Investing": Icons.trending_up,
    "Science": Icons.science,
    "Astronomy": Icons.nights_stay,
    "Math": Icons.calculate,
    "Productivity hacks": Icons.alarm,

    // Lifestyle & Home
    "Fashion": Icons.checkroom,
    "Thrifting": Icons.shopping_bag,
    "Skincare": Icons.spa,
    "Interior design": Icons.chair_alt,
    "Minimalism": Icons.filter_none,
    "Journaling": Icons.book,
    "Bullet journal": Icons.edit_note,
    "Gardening": Icons.grass,
    "House plants": Icons.local_florist,
    "Scented candles": Icons.light,

    // Community & Values
    "Volunteering": Icons.volunteer_activism,
    "Environmentalism": Icons.forest,
    "Animal welfare": Icons.pets,
    "Mental health advocacy": Icons.psychology,
    "Faith & spirituality": Icons.auto_awesome,
    "Local community events": Icons.people,
    "Campus orgs": Icons.school,
    "Charity runs": Icons.directions_run,

    // Pets & Animals
    "Dogs": Icons.pets,
    "Cats": Icons.pets,
    "Aquariums": Icons.water,
    "Birds": Icons.flutter_dash,
    "Reptiles": Icons.emoji_nature,
    "Pet training": Icons.school,
    "Wildlife": Icons.nature,

    // Wheels & Machines
    "Motorcycles": Icons.motorcycle,
    "Scooters": Icons.electric_scooter,
    "Cars": Icons.directions_car,
    "Off-roading": Icons.directions_car_filled,
    "Detailing": Icons.cleaning_services,
    "Motorsports": Icons.flag,
  };

  // Local selection state (labels)
  final Set<String> selected = {};

  // ---- slugify + synonyms ----
  String _slugify(String s) {
    var k = s.trim().toLowerCase();
    k = k.replaceAll('&', 'and').replaceAll('/', ' ');
    k = k.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).join(' ');
    return k.replaceAll(' ', '-');
  }

  static const Map<String, String> _synonyms = {
    "traveling": "travel",
    "video-games": "gaming",
    "pc-gaming": "gaming",
    "board-games": "board-games",
    "diy-crafts": "diy-crafts",
    "run": "running",
    "k-pop": "kpop",
    "j-pop": "jpop",
    "boba-tea": "milk-tea",
  };

  String _toSlug(String label) {
    final raw = label.trim() == "DIY / Crafts" ? "DIY Crafts" : label;
    final slug = _slugify(raw);
    return _synonyms[slug] ?? slug;
  }

  @override
  void initState() {
    super.initState();
    _loadFromPrefs();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLabels = prefs.getStringList(_prefsKeyLabels) ?? const [];
    final allLabels = interestCategories.values.expand((e) => e).toSet();

    setState(() {
      selected
        ..clear()
        ..addAll(savedLabels.where(allLabels.contains));
    });

    widget.onInterestsSelected(selected.toList());
  }

  Future<void> _persistAndNotify() async {
    final prefs = await SharedPreferences.getInstance();
    final labels = selected.toList()..sort();
    final slugs = labels.map(_toSlug).toList();

    await prefs.setStringList(_prefsKeyLabels, labels);
    await prefs.setStringList(_prefsKeySlugs, slugs);

    widget.onInterestsSelected(labels); // notify with labels (unchanged API)
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.of(context).size.width;
    const hPad = 16.0;
    const spacing = 12.0;
    final pillWidth = (width - (hPad * 2) - spacing) / 2;

    final canAddMore = selected.length < widget.maxSelect;

    return ListView(
      padding: const EdgeInsets.all(hPad),
      children: [
        const Text(
          "Let's Get to Know You",
          style: TextStyle(
            color: AppColors.primaryColor,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          "Answer a few questions to help us match you better (2 / 9)",
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: AppColors.primaryColor),
        ),
        const SizedBox(height: 20),

        // Section heading
        const Text(
          "Your Interests",
          style: TextStyle(
            color: AppColors.primaryColor,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),

        Text(
          "Select a few of your interests and let everyone know what you’re passionate about.",
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: AppColors.primaryColor),
        ),
        const SizedBox(height: 16),

        Row(
          children: [
            Text(
              "Selected: ${selected.length}/${widget.maxSelect}",
              style: theme.textTheme.bodySmall,
            ),
            const Spacer(),
            if (!canAddMore)
              Text(
                "Max reached",
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.redAccent),
              ),
          ],
        ),
        const SizedBox(height: 12),

        // Sections
        ...interestCategories.entries.map((entry) {
          final title = entry.key;
          final items = entry.value;

          final base = interestBaseColor(title); // light pastel (outline)
          final border = interestBorderColor(title); // darker (fill/heading)
          final textOn = onPastelText(border); // contrast for selected fill

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title uses category color (more legible if we use the darker one)
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: border, // category-specific heading color
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: items.map((label) {
                  final isSel = selected.contains(label);
                  final icon = interestIcons[label] ??
                      interestIcons[label.trim()] ??
                      Icons.favorite_border;

                  return _InterestPill(
                    label: label,
                    icon: icon,
                    width: pillWidth,
                    selected: isSel,
                    baseColor: base,
                    borderColor: border,
                    textOnPastel: textOn,
                    onTap: () async {
                      if (isSel) {
                        // If already selected, deselect
                        setState(() {
                          selected.remove(label);
                        });
                      } else {
                        // Check max limit before adding
                        if (selected.length >= widget.maxSelect) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                  'You can select up to ${widget.maxSelect} interests only.'),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                          return; // Do not add more
                        }

                        // Add new interest
                        setState(() {
                          selected.add(label);
                        });
                      }

                      // Persist selection & notify parent
                      await _persistAndNotify();
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
            ],
          );
        }).toList(),
      ],
    );
  }
}

class _InterestPill extends StatelessWidget {
  const _InterestPill({
    required this.label,
    required this.icon,
    required this.width,
    required this.selected,
    required this.baseColor,
    required this.borderColor,
    required this.textOnPastel,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final double width;
  final bool selected;
  final Color baseColor; // lighter pastel (outline color)
  final Color borderColor; // darker pastel (selected fill + title)
  final Color
      textOnPastel; // computed from borderColor for selected readability
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tx = Theme.of(context).textTheme;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color:
              selected ? borderColor : Colors.white, // dark fill when selected
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? baseColor : baseColor.withOpacity(0.8), // outline
            width: kInterestPillBorderWidth,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: borderColor.withOpacity(0.25),
                    blurRadius: 12,
                    spreadRadius: 1,
                    offset: const Offset(0, 6),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: selected
                    ? Colors.white.withOpacity(0.18) // subtle halo on selected
                    : const Color(0xFFF8F8F8),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 16,
                color: selected ? textOnPastel : borderColor,
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tx.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: selected ? textOnPastel : borderColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
