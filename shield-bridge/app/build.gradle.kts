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
        versionCode = 2
        versionName = "0.2.0"
    }

    signingConfigs {
        getByName("debug") {
            // A fixed debug key kept in the repo (standard debug passwords), so
            // every CI build updates the installed app in place instead of
            // needing an uninstall that also clears its permissions.
            storeFile = file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("debug")
        }
        release {
            isMinifyEnabled = false
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
