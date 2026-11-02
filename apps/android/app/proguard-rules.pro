# baud-core: uniffi's Kotlin calls into libbaud_ffi.so through JNA, which finds classes, fields
# (Structure's field order) and callbacks by name, so neither may be renamed or removed.
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class sh.rubric.baud.ffi.** { *; }
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
-dontwarn java.awt.**
-dontwarn com.sun.jna.**
