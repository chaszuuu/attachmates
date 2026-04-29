// lib/screens/profile/edit_interests_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../utils/api_client.dart';
import '../../utils/constants.dart';
import '../../utils/interest_categories.dart';

class EditInterestsScreen extends StatefulWidget {
  final List<String> initial; // labels (human form)
  final int minSelect;
  final int maxSelect;

  const EditInterestsScreen({
    super.key,
    this.initial = const [],
    this.minSelect = 3,
    this.maxSelect = 10,
  });

  @override
  State<EditInterestsScreen> createState() => _EditInterestsScreenState();
}

class _EditInterestsScreenState extends State<EditInterestsScreen> {
  final Map<String, List<String>> catalog = kInterestCategories;

  // Selected labels only (exact labels as shown to users)
  final Set<String> selected = {};

  bool _saving = false;
  bool _loading = true;

  // Optional icons (same set you used on InterestsPage)
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

  // ---- Alias map: map backend/alt slugs → a slug that exists in our catalog ----
  // Goal: whatever Firestore stored (slug or label) resolves to a catalog label.
  static const Map<String, String> _synonyms = {
    // travel
    'travel': 'traveling', // backend ➜ catalog
    'traveling': 'traveling',

    // gaming
    'gaming': 'pc-gaming', // backend ➜ catalog "PC gaming"
    'video-games': 'pc-gaming',
    'pc-gaming': 'pc-gaming',

    // board games / diy
    'board-games': 'board-games',
    'diy-crafts': 'diy-crafts',

    // running
    'run': 'running',
    'running': 'running',

    // kpop/jpop
    'kpop': 'k-pop',
    'k-pop': 'k-pop',
    'jpop': 'j-pop',
    'j-pop': 'j-pop',

    // boba / milk tea
    'boba-tea': 'boba-tea',
    'milk-tea': 'boba-tea', // backend ➜ catalog "Boba tea"

    // house plants
    'houseplants': 'house-plants',
    'house-plants': 'house-plants',
  };

  String _slugify(String s) {
    var k = s.trim().toLowerCase();
    k = k.replaceAll('&', 'and').replaceAll('/', ' ');
    k = k.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).join(' ');
    return k.replaceAll(' ', '-');
  }

  // Canonicalize to a slug *that exists* as a key in our catalog mapping
  String _canon(String s) {
    final raw = _slugify(s);
    return _synonyms[raw] ?? raw;
  }

  // Build slug -> representative label map for every label in the catalog,
  // and add alias keys that point to those labels.
  Map<String, String> _buildSlugToLabelIndex() {
    final map = <String, String>{};

    // 1) Add every catalog label by its own slug
    catalog.forEach((_, labels) {
      for (final label in labels) {
        final slug = _slugify(label);
        map.putIfAbsent(slug, () => label);
      }
    });

    // 2) Add alias keys (from _synonyms) that point to an existing label
    _synonyms.forEach((alias, canonicalSlug) {
      final rep = map[canonicalSlug] ?? map[alias];
      if (rep != null) {
        map[alias] = rep;
        map[canonicalSlug] = rep;
      }
    });

    return map;
  }

  // Keep at most one label per conceptual slug
  Set<String> _reconcilePerSlug(
      Set<String> initialLabels, Set<String> storedSlugs) {
    final slugToLabel = _buildSlugToLabelIndex();
    final usedSlugs = <String>{};
    final result = <String>{};

    // Prefer caller-provided labels
    for (final label in initialLabels) {
      final slug = _canon(label);
      if (slug.isEmpty) continue;
      if (usedSlugs.add(slug)) result.add(slugToLabel[slug] ?? label);
    }

    // Then add from Firestore (slugs)
    for (final slug in storedSlugs) {
      if (slug.isEmpty || usedSlugs.contains(slug)) continue;
      final chosen = slugToLabel[slug];
      if (chosen != null) {
        usedSlugs.add(slug);
        result.add(chosen);
      }
    }

    return result;
  }

  @override
  void initState() {
    super.initState();
    // Start with any labels passed in
    selected.addAll(widget.initial.where((e) => e.trim().isNotEmpty));
    // Merge with what's currently in personal_info.interests
    _loadFromFirestore();
  }

  Future<void> _loadFromFirestore() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        setState(() => _loading = false);
        return;
      }

      final snap =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();

      final data = snap.data() ?? {};
      final pinfo = (data['personal_info'] is Map)
          ? Map<String, dynamic>.from(data['personal_info'])
          : const <String, dynamic>{};

      final List<dynamic> list = (pinfo['interests'] is List)
          ? List<dynamic>.from(pinfo['interests'])
          : const [];

      // Normalize stored (labels or slugs) into *catalog-backed slugs*
      final storedSlugs = list
          .map((e) => (e ?? '').toString())
          .where((s) => s.trim().isNotEmpty)
          .map(_canon)
          .toSet();

      final reconciled =
          _reconcilePerSlug(Set<String>.from(selected), storedSlugs);

      setState(() {
        selected
          ..clear()
          ..addAll(reconciled);
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Not signed in'), backgroundColor: Colors.red),
      );
      return;
    }

    if (selected.length < widget.minSelect) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text('Please select at least ${widget.minSelect} interests.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final labels = selected.toList()..sort();

      // Server normalizes and writes to personal_info.interests ONLY
      await ApiClient.postJsonExpectOk('/profile-info', {'interests': labels});

      if (!mounted) return;
      Navigator.pop<List<String>>(context, labels);
    } catch (e) {
      final msg = e.toString();
      final friendly = msg.contains('Select') && msg.contains('interests')
          ? msg
          : 'Failed to save — $msg';
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendly), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.of(context).size.width;
    const hPad = 16.0;
    const spacing = 12.0;
    final pillWidth = (width - (hPad * 2) - spacing) / 2;

    final canAddMore = selected.length < widget.maxSelect;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left,
              color: AppColors.primaryColor, size: 30),
          onPressed: _saving ? null : () => Navigator.pop(context),
          splashRadius: 24,
        ),
        centerTitle: true,
        title: const Text(
          "Edit Interests",
          style: TextStyle(
            color: AppColors.primaryColor,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text(
                    "Save",
                    style: TextStyle(
                      color: AppColors.primaryColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
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
                  "Update your interests to improve your matches",
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: AppColors.primaryColor),
                ),
                const SizedBox(height: 20),
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
                  "Select the things you’re into. We’ll show these on your profile.",
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
                ...catalog.entries.map((entry) {
                  final title = entry.key;
                  final items = entry.value;

                  final base = interestBaseColor(title);
                  final border = interestBorderColor(title);
                  final textOn = onPastelText(border);

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: border,
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
                            onTap: () {
                              if (isSel) {
                                // Deselect if already selected
                                setState(() {
                                  selected.remove(label);
                                });
                              } else {
                                // Prevent selecting beyond max
                                if (selected.length >= widget.maxSelect) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                          'You can select up to ${widget.maxSelect} interests only.'),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                  return; // Do not add extra
                                }

                                setState(() {
                                  selected.add(label);
                                });
                              }
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 20),
                    ],
                  );
                }).toList(),
                const SizedBox(height: 12),
                if (selected.length < widget.minSelect)
                  Text(
                    "Select at least ${widget.minSelect} to save.",
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.redAccent),
                  ),
                const SizedBox(height: 24),
              ],
            ),
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
  final Color baseColor;
  final Color borderColor;
  final Color textOnPastel;
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
          color: selected ? borderColor : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? baseColor : baseColor.withOpacity(0.8),
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
                    ? Colors.white.withOpacity(0.18)
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
