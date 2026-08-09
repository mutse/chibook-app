# google_mlkit_text_recognition compiles against every optional script model.
# chibook only enables Chinese (plus the plugin's default Latin model), so the
# absent Devanagari, Japanese and Korean implementations are intentional.
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
