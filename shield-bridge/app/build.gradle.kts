plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.shieldbridge"
    compileSdk = 34

    defaultConfig {
        applicationId = "dev.shieldbridge"
        // NVIDIA Shield TV runs Android 11 (API 30); 2015/2017 units on Shield
        // Experience 8 are Android 9 (API 28).
        minSdk = 28
        // Stay on 33: Android 14's foreground-service-type requirement adds
        // nothing for a TV box and would complicate installs on older Shields.
        targetSdk = 33
        versionCode = 1
        versionName = "0.1.0"
    }

    signingConfigs {
        // One fixed signing key, committed to the repo on purpose.
        //
        // Android only lets a new APK install over an existing one when both
        // are signed with the same key. Without this block every build uses
        // ~/.android/debug.keystore, which GitHub-hosted runners regenerate on
        // every run, so each CI APK had a different key and `adb install -r`
        // failed with INSTALL_FAILED_UPDATE_INCOMPATIBLE. Uninstalling to get
        // around that also drops the READ_TV_LISTINGS and SYSTEM_ALERT_WINDOW
        // grants the user set up.
        //
        // Shield Bridge is a sideloaded personal app and never goes through the
        // Play Store, so this key does not need to be secret; what matters is
        // that it never changes. The password is deliberately not a secret.
        create("shieldbridge") {
            storeFile = file("shieldbridge-debug.jks")
            storePassword = "shieldbridge"
            keyAlias = "shieldbridge"
            keyPassword = "shieldbridge"
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("shieldbridge")
        }
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("shieldbridge")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // Tiny embeddable HTTP server; the whole LAN API runs on it.
    implementation("org.nanohttpd:nanohttpd:2.3.1")
}
