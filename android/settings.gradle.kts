pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")

check(findProject(":media_kit_libs_android_video") != null) {
    "The Android media_kit native plugin is missing. Run flutter pub get after " +
        "restoring dependency checkouts; do not build with stale plugin metadata."
}

check(file("app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java").isFile) {
    "The Flutter Android plugin registrant is missing. Complete flutter pub get " +
        "successfully before building. For Android-only builds on Windows without " +
        "symlink support, set FLUTTER_WINDOWS=false for the build process."
}
