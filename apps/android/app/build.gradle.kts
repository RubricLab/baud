plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "sh.rubric.baud"
    compileSdk = 35

    defaultConfig {
        applicationId = "sh.rubric.baud"
        minSdk = 26
        targetSdk = 35
        versionName = "0.2.20"
        // The build number, from the UTC clock as on iOS: scripts/ship-android.sh sets it to
        // yyDDDHHmm (year, day of the year, time), because iOS's yyyyMMddHHmm is past Android's
        // ceiling of 2,100,000,000. Local builds are 1.
        versionCode = System.getenv("BAUD_BUILD_NUMBER")?.toIntOrNull() ?: 1
        manifestPlaceholders["appLabel"] = "baud"
        // baud-core is built for arm64 only (phones, and the Apple-silicon emulator).
        ndk { abiFilters += "arm64-v8a" }
    }

    // The release key: a PKCS12 keystore outside the repo, its password from the login keychain
    // (or BAUD_RELEASE_PASSWORD, which the ship script sets from the same place). Read only when a
    // release is being built, so debug builds never touch the keychain.
    val wantsRelease = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
    val releaseKey = file("${System.getProperty("user.home")}/.android-keys/baud-release.jks")
    val releasePassword: String? = if (!wantsRelease || !releaseKey.exists()) null else
        System.getenv("BAUD_RELEASE_PASSWORD") ?: providers.exec {
            commandLine("security", "find-generic-password", "-a", "baud-android", "-s", "baud android release key", "-w")
        }.standardOutput.asText.get().trim()
    signingConfigs {
        if (releasePassword != null) create("release") {
            storeFile = releaseKey
            storeType = "pkcs12"
            storePassword = releasePassword
            keyAlias = "baud"
            keyPassword = releasePassword
        }
    }

    buildTypes {
        debug {
            // Its own app next to the shipped one (as iOS's .dev builds): its own store and keys.
            applicationIdSuffix = ".dev"
            manifestPlaceholders["appLabel"] = "baud dev"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfigs.findByName("release")?.let { signingConfig = it }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
        // cargo-ndk copies every cdylib in the core's graph; libbaud_ffi.so links none of them.
        jniLibs.excludes += listOf("**/libiroh.so", "**/libiroh_relay.so", "**/libirpc-*.so")
    }
    // baud-core's generated Kotlin (core/scripts/bindings.sh), copied in from where it is made
    // (see `bindings` below); its libbaud_ffi.so lands in src/main/jniLibs/arm64-v8a.
    sourceSets["main"].java.srcDir(layout.buildDirectory.dir("generated/baud"))
}

// baud-core for the phone: core/scripts/build-android.sh (rustup's cargo, cargo-ndk, the NDK)
// writes libbaud_ffi.so into src/main/jniLibs (ignored by git) and regenerates the bindings. It runs
// only when the .so is missing or older than the core's sources.
val core = rootDir.resolve("../../core")
val coreLib = file("src/main/jniLibs/arm64-v8a/libbaud_ffi.so")
val buildCore by tasks.registering(Exec::class) {
    workingDir = core
    commandLine("bash", "scripts/build-android.sh", file("src/main/jniLibs").absolutePath)
    onlyIf {
        if (!core.resolve("scripts/build-android.sh").exists()) return@onlyIf false
        if (!coreLib.exists()) return@onlyIf true
        val built = coreLib.lastModified()
        val sources = listOf("baud-core", "baud-ffi").map { core.resolve(it) }.flatMap { d -> d.walkTopDown().filter { it.isFile && "/target/" !in it.path }.toList() } +
            listOf("Cargo.toml", "Cargo.lock").map { core.resolve(it) }
        sources.any { it.lastModified() > built }
    }
}

// The bindings as generated, copied in. (Until the core renamed it, `Baud`'s `suspend close()`
// clashed with AutoCloseable's; the rename stays here as a no-op guard.)
val bindings by tasks.registering(Copy::class) {
    dependsOn(buildCore)
    from(core.resolve("bindings/kotlin"))
    into(layout.buildDirectory.dir("generated/baud"))
    filter { line: String -> line.replace("suspend fun `close`()", "suspend fun `shutdown`()") }
}
tasks.named("preBuild") { dependsOn(bindings) }

dependencies {
    val compose = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(compose)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")
    implementation("androidx.exifinterface:exifinterface:1.3.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    // uniffi's Kotlin calls into the core through JNA.
    implementation("net.java.dev.jna:jna:5.15.0@aar")

    // The QR: drawn and read with ZXing's core, the camera with CameraX. Nothing from Google Play
    // services, so baud runs on phones without them.
    implementation("com.google.zxing:core:3.5.3")
    val camerax = "1.4.1"
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    implementation("androidx.camera:camera-view:$camerax")

    // The tones' contrast, checked and printed on the JVM (TonesTest).
    testImplementation("junit:junit:4.13.2")
}
