import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

dependencies {
    // 🔹 Firebase BoM
    implementation(platform("com.google.firebase:firebase-bom:33.16.0"))

    // 🔹 Material Components (required for Theme.Material3.* + colorOnPrimary, etc.)
    implementation("com.google.android.material:material:1.12.0")

    // 🔹 Required for flutter_local_notifications (Java 8+ APIs like java.time)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    // (Add your other implementation(...) deps here if you have any)
}

android {
    namespace = "com.it09.attachmates"

    // === Updated SDK & NDK ===
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        // ✅ Enable core library desugaring
        isCoreLibraryDesugaringEnabled = true

        // ✅ Use Java 11 for modern APIs
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.it09.attachmates"

        // ✅ Minimum SDK for modern libraries (flutter_sound, etc.)
        minSdk = 24
        targetSdk = 36

        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Optional: enable multidex if you hit 64K method limit later
        // multiDexEnabled = true
    }

    // ── Load keystore from android/key.properties ──────────────────────────
    val keystoreProperties = Properties()
    val keystoreFile = rootProject.file("key.properties")
    if (keystoreFile.exists()) {
        keystoreProperties.load(keystoreFile.inputStream())
    } else {
        logger.warn("⚠️ key.properties not found – release will build unsigned unless you add it.")
    }

    signingConfigs {
        // Release signing config (uses key.properties if present)
        create("release") {
            if (keystoreFile.exists()) {
                val storeFilePath = keystoreProperties["storeFile"] as String
                storeFile = file(storeFilePath)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        debug {
            // keep debug as is
            signingConfig = signingConfigs.getByName("debug")
        }
        release {
            // ✅ Sign with the real release keystore (if key.properties exists)
            signingConfig = signingConfigs.getByName("release")

            // Optimize release
            isMinifyEnabled = true
            isShrinkResources = true

            // Optional: keep rules if you use ProGuard/R8
            // proguardFiles(
            //     getDefaultProguardFile("proguard-android-optimize.txt"),
            //     "proguard-rules.pro"
            // )
        }
    }
}

flutter {
    source = "../.."
}
