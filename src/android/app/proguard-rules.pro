-keep, includedescriptorclasses class org.rustls.platformverifier.** { *; }

# Keep audio_service and Android media components
-keep class com.ryanheise.audioservice.** { *; }
-keep class androidx.media3.** { *; }
-keep class android.support.v4.media.** { *; }
