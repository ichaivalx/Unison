plugins { id("com.android.application") }

android {
    namespace = "io.github.ichaivalx.unison"
    compileSdk = 36
    ndkVersion = "30.0.16248370"
    defaultConfig {
        applicationId = "io.github.ichaivalx.unison"
        minSdk = 33
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
        ndk { abiFilters += "arm64-v8a" }
        externalNativeBuild { cmake { cppFlags += "-std=c++17" } }
    }
    signingConfigs {
        getByName("debug") {
            storeFile = rootProject.file("debug.p12")
            storePassword = "android"
            keyAlias = "unison"
            keyPassword = "android"
            storeType = "PKCS12"
        }
    }
    packaging { jniLibs { useLegacyPackaging = true } }
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "4.1.2"
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies { implementation(project(":capture")) }
