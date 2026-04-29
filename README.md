<div align="center">
  <img src="https://raw.githubusercontent.com/chaszuuu/attachmates/main/assets/UI/logo.png" alt="Attachmates Logo" width="180"/>
  <h1>AttachMates</h1>
  <p><strong>Psychology-powered dating — because real connections start with emotional understanding.</strong></p>

  ![License](https://img.shields.io/badge/license-MIT-pink?style=flat-square)
  ![Status](https://img.shields.io/badge/status-in%20development-orange?style=flat-square)
  ![Platform](https://img.shields.io/badge/platform-Android-blueviolet?style=flat-square)
  ![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?style=flat-square&logo=flutter)
  ![Python](https://img.shields.io/badge/Python-FastAPI-009688?style=flat-square&logo=fastapi)
  ![Firebase](https://img.shields.io/badge/Firebase-Firestore%20%7C%20Auth-FFCA28?style=flat-square&logo=firebase)
  ![Supabase](https://img.shields.io/badge/Supabase-Storage-3ECF8E?style=flat-square&logo=supabase)
</div>

---

## What is AttachMates?

Most dating apps prioritize physical appearance and fast interactions — and that leads to emotional mismatches, inconsistent connections, and dating fatigue. **AttachMates** takes a different approach.

Built on **Attachment Theory** (Bowlby & Ainsworth) and the **Five Love Languages Framework** (Chapman), AttachMates matches users based on psychological compatibility — not just profile pictures. Our AI-powered hybrid recommendation system analyzes your attachment style and love language to surface partners who genuinely align with how you connect and love.

Whether you're securely attached, anxiously bonded, or somewhere in between, AttachMates finds people who complement that — and helps you understand yourself better along the way.

---

## Screenshots

<div align="center">

### Splash & Auth
<img src="https://raw.githubusercontent.com/chaszuuu/attachmates/main/assets/UI/splash_screen.jpg" alt="Splash Screen" width="250"/>
<img src="https://raw.githubusercontent.com/chaszuuu/attachmates/main/assets/UI/auth.jpg" alt="Auth Screen" width="250"/>

### Compatibility Quiz
<img src="https://raw.githubusercontent.com/chaszuuu/attachmates/main/assets/UI/quiz.jpg" alt="Quiz" width="250"/>
<img src="https://raw.githubusercontent.com/chaszuuu/attachmates/main/assets/UI/quiz2.jpg" alt="Quiz 2" width="250"/>

### Discover & Matches
<img src="https://raw.githubusercontent.com/chaszuuu/attachmates/main/assets/UI/discover.jpg" alt="Discover" width="250"/>
<img src="https://raw.githubusercontent.com/chaszuuu/attachmates/main/assets/UI/matches.jpg" alt="Matches" width="250"/>

### Messages & Profile
<img src="https://raw.githubusercontent.com/chaszuuu/attachmates/main/assets/UI/messages.jpg" alt="Messages" width="250"/>
<img src="https://raw.githubusercontent.com/chaszuuu/attachmates/main/assets/UI/convo.jpg" alt="Conversation" width="250"/>
<img src="https://raw.githubusercontent.com/chaszuuu/attachmates/main/assets/UI/profile.jpg" alt="Profile" width="250"/>

</div>

---

## Features

### Built-in Psychological Assessment
Users complete two in-app assessments before matching: the **LoveByte Test** (Adult Attachment Style Scale) to identify their attachment style, and **The Five Love Languages Test** to determine how they give and receive love. These results form the core of every match.

### AI-Powered Hybrid Matching
AttachMates uses a hybrid recommendation system combining **rule-based filtering** (psychological profiles) and **content-based recommendations** (user preferences) to generate personalized, emotionally compatible match suggestions. Matches only occur when both users mutually like each other.

### Attachment Style Profiling
Based on Bowlby and Ainsworth's Attachment Theory, the app identifies where each user falls across four styles — **Secure, Anxious, Avoidant, and Disorganized** — and uses this as a foundational signal in the matching algorithm.

### Private & Secure Messaging
Matched users can communicate through text, photos, and short voice messages. All media is securely stored and managed via **Supabase Storage**.

### Orientation-Based Filtering
Users can filter potential matches by gender identity and sexual orientation, making the platform inclusive and personalized.

### Safe Match Verification
A manual ID review process confirms user identity, prevents fake profiles, and builds trust across the platform.

### Regular Reassessment
The app periodically prompts users to retake assessments, ensuring that match recommendations reflect their current emotional state and preferences.

### Privacy First
Firebase Authentication and Firestore security rules protect all user data. A server-side blocklist prevents blocked profiles from appearing on either end. No data is sold to third parties, and users can delete their profile at any time.

### Minimized Dating Fatigue
By focusing on psychological compatibility over endless swiping, AttachMates surfaces fewer but more meaningful matches — reducing the burnout that commonly comes with traditional dating apps.

---

## How the Matching Works

The matching engine is built on three pillars:

1. **Attachment Style Analysis** — Derived from the onboarding LoveByte Test (Adult Attachment Style Scale), adapted with expert validation.
2. **Love Language Scoring** — Based on Chapman's Five Love Languages: Words of Affirmation, Acts of Service, Receiving Gifts, Quality Time, and Physical Touch.
3. **Hybrid Recommendation Logic** — Combines rule-based filtering (psychological compatibility) with content-based recommendations (user interests and preferences) to rank and suggest compatible matches.

The algorithm prioritizes emotional compatibility and filters out incompatible profiles based on contradictory attachment styles or mismatched love language needs.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Mobile (Android) | Flutter 3.x / Dart 3.x |
| Backend API | Python / FastAPI |
| AI / ML Matching | Python — OpenAI Text Embedding |
| Authentication | Firebase Authentication |
| Database | Firebase Firestore |
| Media Storage | Supabase Storage |
| Notifications | Firebase Cloud Messaging |

---

## Repositories

| Repo | Description |
|---|---|
| [`attachmates`](https://github.com/chaszuuu/attachmates) | Flutter frontend — Android app |
| [`attachmates-backend`](https://github.com/chaszuuu/attachmates-backend) | Python / FastAPI — AI matching engine, REST API, Firebase integration |

---

## Getting Started (Frontend)

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) `>= 3.x`
- Dart `>= 3.x` (bundled with Flutter)
- Android Studio
- A running instance of the [AttachMates backend](https://github.com/chaszuuu/attachmates-backend)

### Installation

```bash
# Clone the frontend repo
git clone https://github.com/chaszuuu/attachmates.git
cd attachmates

# Install dependencies
flutter pub get

# Set up environment variables
cp .env.example .env
# Set your API base URL and Firebase/Supabase keys in .env

# Run on a connected device or emulator
flutter run
```

### Building for Release

```bash
# Android APK
flutter build apk --release

# Android App Bundle
flutter build appbundle --release
```

### Environment Variables

```env
BASE_URL=
# Add Firebase and Supabase keys as needed
```

> Secrets are excluded via `.gitignore`. Never commit `.env` or credentials.

---

## Project Structure
attachmates/
│
front_end/
├── android/                  # Android native configuration
├── assets/                   # App assets (images, icons, UI fonts)
│   └── UI/                   # README screenshots & branding assets
├── ios/                      # iOS native configuration
├── lib/                      # Main Flutter application source code
│   ├── core/                 # Global constants, themes, services, utilities
│   ├── models/               # Data models (User, Match, Quiz, Chat, etc.)
│   ├── screens/              # UI screens
│   │   ├── splash/           # Splash screen
│   │   ├── auth/             # Login, register, onboarding
│   │   ├── quiz/             # LoveByte & Love Language assessments
│   │   ├── discover/         # Discover & recommendation feed
│   │   ├── matches/          # Match list
│   │   ├── chat/             # Messaging interface
│   │   └── profile/          # User profile & settings
│   ├── widgets/              # Reusable UI components
│   ├── services/             # Firebase, Supabase, API integrations
│   ├── providers/            # State management (Provider / Riverpod / Bloc)
│   ├── routes/               # App navigation & route definitions
│   └── main.dart             # App entry point
├── linux/                    # Linux desktop support
├── macos/                    # macOS desktop support
├── test/                     # Unit & widget tests
├── web/                      # Web support
├── windows/                  # Windows desktop support
├── .gitignore                # Ignored files
├── analysis_options.yaml     # Dart analyzer configuration
├── cert.der                  # Security certificate
├── pubspec.yaml              # Flutter dependencies & assets config
├── pubspec.lock              # Locked dependency versions
└── README.md                 # Project documentation

---

## Roadmap

- [x] Core onboarding & attachment style profiling
- [x] Love language assessment
- [x] Hybrid AI compatibility matching
- [x] Match discovery feed
- [x] Private & secure messaging (text, photo, voice)
- [x] Orientation-based filtering
- [x] Manual ID verification
- [x] Server-side blocklist
- [x] Firebase authentication & data security
- [x] Supabase media storage
- [ ] iOS version
- [ ] Expanded user capacity (beyond 100-user prototype)
- [ ] Enhanced AI model with larger datasets
- [ ] Relationship guidance & compatibility breakdown UI
- [ ] Premium tier & subscriptions
- [ ] Community safety tools

---

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](./CONTRIBUTING.md) before submitting a PR.

1. Fork the project
2. Create your feature branch (`git checkout -b feature/your-feature`)
3. Commit your changes (`git commit -m 'Add some feature'`)
4. Push to the branch (`git push origin feature/your-feature`)
5. Open a Pull Request

---

## License

This project is licensed under the MIT License. See [LICENSE](./LICENSE) for details.

---

## Contact

Built with love (and psychology) by [@chaszuuu](https://github.com/chaszuuu).

---

<div align="center">Made for people who want to connect <em>for real</em>. 💘</div>
