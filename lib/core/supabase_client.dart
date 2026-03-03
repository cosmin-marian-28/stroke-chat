import 'package:supabase_flutter/supabase_flutter.dart';

class SupaConfig {
  static const String url = 'https://dgwbbbkqripzscvtcnjf.supabase.co';
  static const String anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRnd2JiYmtxcmlwenNjdnRjbmpmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzEzMDIwNDUsImV4cCI6MjA4Njg3ODA0NX0.IbaANWcJUqScobxJ0gT5T_3y55sNYJX9_E9PsMIGPws';

  static SupabaseClient get client => Supabase.instance.client;

  static Future<void> init() async {
    await Supabase.initialize(url: url, anonKey: anonKey);
  }
}
