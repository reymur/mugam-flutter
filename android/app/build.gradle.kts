plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.mugam.mugam_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.mugam.mugam_flutter"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // AGP 9 turned R8 minification on by default for release builds
            // even though this project never configured any keep rules for
            // it — caused a real crash (WorkManager's Room-generated
            // WorkDatabase_Impl constructor stripped, NoSuchMethodException
            // on launch) since androidx.work's own consumer proguard rules
            // didn't get applied correctly under this AGP/R8 combination.
            // Off until keep rules are deliberately set up.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Backs NativeVideoCompressorPlugin.kt — official, actively-maintained
    // Google library wrapping the same MediaCodec+MediaMuxer+OpenGL pipeline
    // a hand-rolled transcoder would need, without us owning that OpenGL
    // rendering layer ourselves (see git history for why: raw Surface-to-
    // Surface MediaCodec transcoding requires a manual EGL/shader resize
    // step that's real production risk — device/GPU-specific bugs — for a
    // chat app's video compression feature).
    implementation("androidx.media3:media3-transformer:1.10.1")
    implementation("androidx.media3:media3-common:1.10.1")
    implementation("androidx.media3:media3-effect:1.10.1")
}

flutter {
    source = "../.."
}
