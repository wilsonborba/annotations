plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.asodya.annotations"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.asodya.annotations"
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
        }
    }
}

flutter {
    source = "../.."
}

val buildKrillaAndroid by tasks.registering {
    val crateDir = file("../../../../native/pdf_krilla_spike")
    val jniDir = file("src/main/jniLibs")
    inputs.files(file("$crateDir/Cargo.toml"), file("$crateDir/src/lib.rs"))
    outputs.dir(jniDir)
    doLast {
        val ndkDir = android.ndkDirectory
        val llvmBin = file("$ndkDir/toolchains/llvm/prebuilt/linux-x86_64/bin")
        val abis = listOf(
            Triple("aarch64-linux-android", "arm64-v8a", "aarch64-linux-android24-clang"),
            Triple("armv7-linux-androideabi", "armeabi-v7a", "armv7a-linux-androideabi24-clang"),
            Triple("x86_64-linux-android", "x86_64", "x86_64-linux-android24-clang"),
            Triple("i686-linux-android", "x86", "i686-linux-android24-clang"),
        )
        val cargoHome = file("${System.getProperty("user.home")}/.cargo/bin")
        val cargoExe = file("$cargoHome/cargo").let { if (it.exists()) it.absolutePath else "cargo" }
        val pathWithCargo = "${cargoHome.absolutePath}:${System.getenv("PATH") ?: ""}"
        for ((target, abi, clang) in abis) {
            val envKey = "CARGO_TARGET_${target.uppercase().replace('-', '_')}_LINKER"
            val linker = file("$llvmBin/$clang").absolutePath
            exec {
                workingDir = crateDir
                environment("PATH", pathWithCargo)
                environment(envKey, linker)
                commandLine(cargoExe, "build", "--release", "--lib", "--target", target)
            }
            val outAbiDir = file("$jniDir/$abi")
            outAbiDir.mkdirs()
            copy {
                from("$crateDir/target/$target/release/libpdf_krilla_spike.so")
                into(outAbiDir)
            }
        }
    }
}

tasks.named("preBuild") {
    dependsOn(buildKrillaAndroid)
}
